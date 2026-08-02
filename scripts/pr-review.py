#!/usr/bin/env python3
"""Owner-triggered PR review runner for pipelock-agent-egress-action."""

import json
import os
import sys

import requests

MAX_DIFF_CHARS = 100_000
DEFAULT_MODEL_FAST = "gpt-5.6-luna"
DEFAULT_MODEL_DEEP = "gpt-5.6-terra"
DEFAULT_TEMPERATURE = 0.2
DEFAULT_MAX_COMPLETION_TOKENS = 8192
DEEP_MAX_COMPLETION_TOKENS = 25000
DEFAULT_LLM_TIMEOUT_SECONDS = 120
DEEP_LLM_TIMEOUT_SECONDS = 300
FAST_REASONING_EFFORT = "low"
DEEP_REASONING_EFFORT = "medium"


class LLMReviewError(RuntimeError):
    """Raised when an LLM response cannot provide a usable review."""


SYSTEM_PROMPT = """You are reviewing a pull request for pipelock-agent-egress-action, a composite GitHub Action that runs one script in a constrained network boundary and produces an audit packet from Pipelock receipts.

Focus on correctness and security properties that could make the action overclaim enforcement or evidence, allow an escape from the intended action boundary, or invalidate the audit packet.

Flag:
- shell, path, input, environment, and GitHub Actions expression injection
- fail-open behavior in egress containment, receipt verification, or cleanup
- unsafe privilege, namespace, filesystem, network, or process handling
- action inputs that can escape their documented working-directory boundary
- gaps between README claims and the actual action boundary
- error handling that hides failed verification or leaves dangerous state behind
- changes that weaken pinned-action, trusted-evidence, or immutable-reference guidance

Do not spend time on style nits. Be direct and specific. For each finding include severity, file and function, why it matters, and a concrete fix. If there are no material issues, say exactly: No material issues found in this diff."""


def get_pr_diff(repo: str, pr_number: str, token: str) -> str:
    """Fetch the pull request diff through GitHub's API."""
    response = requests.get(
        f"https://api.github.com/repos/{repo}/pulls/{pr_number}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github.v3.diff"},
        timeout=30,
    )
    response.raise_for_status()
    return response.text


def truncate_diff(diff: str, max_chars: int = MAX_DIFF_CHARS) -> str:
    """Keep review input within a bounded request size."""
    if len(diff) <= max_chars:
        return diff
    return diff[:max_chars] + f"\n\n... (diff truncated at {max_chars} chars, {len(diff)} total)"


def model_supports_custom_temperature(model: str) -> bool:
    """Return whether a chat model accepts a non-default temperature."""
    return not model.strip().lower().rsplit("/", 1)[-1].startswith(("gpt-5", "o1", "o3", "o4"))


def model_supports_reasoning_effort(model: str) -> bool:
    """Return whether a model supports the Chat Completions reasoning control."""
    return model.strip().lower().rsplit("/", 1)[-1].startswith(("gpt-5", "o1", "o3", "o4"))


def model_for_mode(mode: str) -> str:
    """Select the reviewed Python default unless a repository variable overrides it."""
    if mode == "deep":
        return os.environ.get("PR_REVIEW_MODEL_DEEP") or DEFAULT_MODEL_DEEP
    return os.environ.get("PR_REVIEW_MODEL_FAST") or DEFAULT_MODEL_FAST


def build_llm_payload(model: str, diff: str, *, max_completion_tokens: int = DEFAULT_MAX_COMPLETION_TOKENS, reasoning_effort: str = FAST_REASONING_EFFORT) -> dict:
    """Build a GPT-5-compatible Chat Completions request."""
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"Review this pull request diff:\n\n```diff\n{diff}\n```"},
        ],
        "max_completion_tokens": max_completion_tokens,
    }
    if model_supports_custom_temperature(model):
        payload["temperature"] = DEFAULT_TEMPERATURE
    if model_supports_reasoning_effort(model):
        payload["reasoning_effort"] = reasoning_effort
    return payload


def summarize_usage(data: dict) -> str:
    """Return compact usage details for a truncated or empty model response."""
    usage = data.get("usage")
    if not isinstance(usage, dict):
        return "usage unavailable"
    details = usage.get("completion_tokens_details") or {}
    parts = [f"prompt={usage.get('prompt_tokens', 'unknown')}", f"completion={usage.get('completion_tokens', 'unknown')}", f"total={usage.get('total_tokens', 'unknown')}"]
    if isinstance(details, dict) and "reasoning_tokens" in details:
        parts.append(f"reasoning={details['reasoning_tokens']}")
    return ", ".join(parts)


def extract_chat_content(data: dict) -> str:
    """Extract visible text from a Chat Completions response."""
    choices = data.get("choices", [])
    if not isinstance(choices, list) or not choices:
        raise LLMReviewError("LLM returned no choices.")
    choice = choices[0] if isinstance(choices[0], dict) else {}
    message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
    content = message.get("content", "")
    if isinstance(content, list):
        content = "".join(part.get("text", "") for part in content if isinstance(part, dict))
    if isinstance(content, str) and content.strip():
        if choice.get("finish_reason") == "length":
            content += "\n\n> **Warning:** Review output was truncated by the model completion limit (" + summarize_usage(data) + "). Treat this as an incomplete review and rerun with a narrower diff if needed."
        return content
    raise LLMReviewError("LLM returned empty content (finish_reason=" + str(choice.get("finish_reason", "unknown")) + "; " + summarize_usage(data) + ").")


def call_llm(diff: str, mode: str) -> str:
    """Call the configured endpoint and return a review or a useful error."""
    litellm_url = os.environ.get("LITELLM_BASE_URL", "")
    litellm_key = os.environ.get("LITELLM_API_KEY", "")
    openai_key = os.environ.get("OPENAI_API_KEY", "")
    if litellm_url and litellm_key:
        api_url, api_key = litellm_url.rstrip("/") + "/chat/completions", litellm_key
    elif openai_key:
        api_url, api_key = "https://api.openai.com/v1/chat/completions", openai_key
    else:
        raise LLMReviewError("No LLM API configured. Set LITELLM_BASE_URL + LITELLM_API_KEY or OPENAI_API_KEY in repository secrets.")
    deep = mode == "deep"
    model = model_for_mode(mode)
    response = requests.post(
        api_url,
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        json=build_llm_payload(model, diff, max_completion_tokens=DEEP_MAX_COMPLETION_TOKENS if deep else DEFAULT_MAX_COMPLETION_TOKENS, reasoning_effort=DEEP_REASONING_EFFORT if deep else FAST_REASONING_EFFORT),
        timeout=DEEP_LLM_TIMEOUT_SECONDS if deep else DEFAULT_LLM_TIMEOUT_SECONDS,
    )
    if response.status_code != 200:
        raise LLMReviewError(
            f"LLM API returned {response.status_code} for model `{model}`."
        )
    try:
        data = response.json()
    except (json.JSONDecodeError, ValueError) as error:
        raise LLMReviewError("LLM returned invalid JSON.") from error
    if not isinstance(data, dict):
        raise LLMReviewError("LLM returned a non-object JSON response.")
    return extract_chat_content(data)


def post_comment(repo: str, pr_number: str, token: str, body: str) -> None:
    """Post a single review comment to the pull request."""
    response = requests.post(
        f"https://api.github.com/repos/{repo}/issues/{pr_number}/comments",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github.v3+json"},
        json={"body": body},
        timeout=30,
    )
    response.raise_for_status()


def main() -> None:
    token, repo, pr_number = os.environ.get("GITHUB_TOKEN", ""), os.environ.get("REPO", ""), os.environ.get("PR_NUMBER", "")
    mode = os.environ.get("REVIEW_MODE", "default")
    if not all([token, repo, pr_number]):
        print("Missing required environment variables", file=sys.stderr)
        sys.exit(1)
    try:
        diff = get_pr_diff(repo, pr_number, token)
    except requests.RequestException as error:
        post_comment(repo, pr_number, token, f"**AI Review Error:** Failed to fetch PR diff: {error}")
        sys.exit(1)
    if not diff.strip():
        post_comment(repo, pr_number, token, "**AI Review:** No diff found for this PR.")
        return
    try:
        review = call_llm(truncate_diff(diff), mode)
    except (requests.RequestException, LLMReviewError) as error:
        post_comment(repo, pr_number, token, f"**AI Review Error:** LLM API call failed: {error}")
        sys.exit(1)
    command = "/review" if mode == "default" else "/review deep"
    header = f"## AI Security Review (`{command}`)\n\n**Model:** `{model_for_mode(mode)}`\n\n---\n\n"
    post_comment(repo, pr_number, token, header + review)


if __name__ == "__main__":
    main()
