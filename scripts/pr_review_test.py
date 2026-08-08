#!/usr/bin/env python3
"""Focused tests for the owner-triggered PR review runner."""

import importlib.util
import pathlib
import unittest
from unittest import mock

SCRIPT_PATH = pathlib.Path(__file__).with_name("pr-review.py")
WORKFLOW_PATH = SCRIPT_PATH.parents[1] / ".github" / "workflows" / "pr-review.yaml"
SPEC = importlib.util.spec_from_file_location("pr_review", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"failed to load {SCRIPT_PATH}")
pr_review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pr_review)


class FakeResponse:
    def __init__(self, data, status_code=200, text=""):
        self._data, self.status_code, self.text = data, status_code, text

    def json(self):
        return self._data


class InvalidJSONResponse(FakeResponse):
    def json(self):
        raise ValueError("not JSON")


class RoutingTest(unittest.TestCase):
    def test_review_modes_have_exact_gpt56_defaults(self):
        self.assertEqual(pr_review.DEFAULT_MODEL_FAST, "gpt-5.6-luna")
        self.assertEqual(pr_review.DEFAULT_MODEL_DEEP, "gpt-5.6-terra")

    def test_default_and_deep_modes_cannot_swap_routes(self):
        response = FakeResponse({"choices": [{"message": {"content": "review"}}]})
        with mock.patch.dict(pr_review.os.environ, {"OPENAI_API_KEY": "test-key"}, clear=True), mock.patch.object(pr_review.requests, "post", return_value=response) as post:
            pr_review.call_llm("diff", "default")
            default_payload = post.call_args.kwargs["json"]
            pr_review.call_llm("diff", "deep")
            deep_payload = post.call_args.kwargs["json"]
        self.assertEqual(default_payload["model"], "gpt-5.6-luna")
        self.assertEqual(default_payload["reasoning_effort"], "low")
        self.assertEqual(default_payload["max_completion_tokens"], 8192)
        self.assertNotIn("temperature", default_payload)
        self.assertEqual(deep_payload["model"], "gpt-5.6-terra")
        self.assertEqual(deep_payload["reasoning_effort"], "xhigh")
        self.assertEqual(deep_payload["max_completion_tokens"], 64000)

    def test_empty_overrides_fall_back_to_reviewed_defaults(self):
        with mock.patch.dict(pr_review.os.environ, {"PR_REVIEW_MODEL_FAST": "", "PR_REVIEW_MODEL_DEEP": ""}, clear=True):
            self.assertEqual(pr_review.model_for_mode("default"), "gpt-5.6-luna")
            self.assertEqual(pr_review.model_for_mode("deep"), "gpt-5.6-terra")

    def test_workflow_uses_owner_gate_and_trusted_default_branch(self):
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertIn("github.event.comment.user.login == 'luckyPipewrench'", workflow)
        self.assertIn("github.event.comment.author_association == 'OWNER'", workflow)
        self.assertIn("github.event.issue.pull_request", workflow)
        self.assertIn("ref: ${{ github.event.repository.default_branch }}", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("timeout-minutes: 10", workflow)
        self.assertIn("group: pr-review-${{ github.repository }}-${{ github.event.issue.number }}", workflow)
        self.assertIn("cancel-in-progress: true", workflow)
        self.assertIn("python -m unittest scripts/pr_review_test.py", workflow)
        self.assertIn("PR_REVIEW_MODEL_FAST: ${{ vars.PR_REVIEW_MODEL_FAST }}", workflow)
        self.assertIn("PR_REVIEW_MODEL_DEEP: ${{ vars.PR_REVIEW_MODEL_DEEP }}", workflow)
        self.assertNotRegex(workflow, r"PR_REVIEW_MODEL_(?:FAST|DEEP): gpt-")


class ResponseTest(unittest.TestCase):
    def test_shape_errors_are_generic_and_fail_closed(self):
        with self.assertRaises(pr_review.LLMReviewError) as ctx:
            pr_review.extract_chat_content({"choices": [], "private": "provider detail"})
        self.assertIn("no choices", str(ctx.exception))
        self.assertNotIn("provider detail", str(ctx.exception))

        with self.assertRaisesRegex(pr_review.LLMReviewError, "empty content"):
            pr_review.extract_chat_content({"choices": [None]})

    def test_content_parts_and_truncated_response_are_handled(self):
        content = pr_review.extract_chat_content({"choices": [{"finish_reason": "length", "message": {"content": [{"type": "text", "text": "partial "}, {"type": "text", "text": "review"}]}}], "usage": {"completion_tokens_details": {"reasoning_tokens": 1200}}})
        self.assertIn("partial review", content)
        self.assertIn("incomplete review", content)

    def test_empty_content_is_rejected(self):
        with self.assertRaisesRegex(pr_review.LLMReviewError, "empty content"):
            pr_review.extract_chat_content({"choices": [{"message": {"content": ""}}]})

    def test_non_200_and_invalid_json_are_rejected(self):
        with mock.patch.dict(pr_review.os.environ, {"OPENAI_API_KEY": "test-key"}, clear=True), mock.patch.object(pr_review.requests, "post", return_value=FakeResponse({}, 500, "boom")):
            with self.assertRaises(pr_review.LLMReviewError) as ctx:
                pr_review.call_llm("diff", "default")
        self.assertIn("returned 500", str(ctx.exception))
        self.assertNotIn("boom", str(ctx.exception))
        with mock.patch.dict(pr_review.os.environ, {"OPENAI_API_KEY": "test-key"}, clear=True), mock.patch.object(pr_review.requests, "post", return_value=InvalidJSONResponse({})):
            with self.assertRaisesRegex(pr_review.LLMReviewError, "invalid JSON"):
                pr_review.call_llm("diff", "default")
        with mock.patch.dict(pr_review.os.environ, {"OPENAI_API_KEY": "test-key"}, clear=True), mock.patch.object(pr_review.requests, "post", return_value=FakeResponse([])):
            with self.assertRaisesRegex(pr_review.LLMReviewError, "non-object JSON"):
                pr_review.call_llm("diff", "default")


if __name__ == "__main__":
    unittest.main()
