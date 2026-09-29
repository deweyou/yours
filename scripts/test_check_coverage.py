import tempfile
import unittest
from pathlib import Path
from check_coverage import evaluate


class CoverageGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.entries = []
        for name, covered in [("NoteStore.swift", 95), ("NativeRichTextEditor.swift", 60), ("WorkspaceView.swift", 0)]:
            path = self.root / name
            path.touch()
            self.entries.append({"filename": str(path), "summary": {"lines": {"count": 100, "covered": covered}}})

    def report(self):
        return {"data": [{"files": self.entries}]}

    def test_accepts_baseline(self):
        self.assertTrue(evaluate(self.report(), self.root)[0])

    def test_rejects_core_regression(self):
        self.entries[0]["summary"]["lines"]["covered"] = 89
        self.assertFalse(evaluate(self.report(), self.root)[0])

    def test_rejects_bridge_regression(self):
        self.entries[1]["summary"]["lines"]["covered"] = 54
        self.assertFalse(evaluate(self.report(), self.root)[0])

    def test_new_source_cannot_disappear(self):
        (self.root / "NewFeature.swift").touch()
        with self.assertRaises(ValueError):
            evaluate(self.report(), self.root)

    def test_ios_only_workspace_is_explicitly_reported_on_mac(self):
        (self.root / "App").mkdir()
        (self.root / "App/MobileWorkspaceView.swift").touch()
        passed, summary = evaluate(self.report(), self.root)
        self.assertTrue(passed)
        self.assertIn("Not compiled on macos: App/MobileWorkspaceView.swift", summary)
        with self.assertRaises(ValueError):
            evaluate(self.report(), self.root, "ios")

    def test_mac_workspace_still_requires_coverage_on_mac(self):
        (self.root / "App").mkdir()
        (self.root / "App/MacWorkspaceView.swift").touch()
        with self.assertRaises(ValueError):
            evaluate(self.report(), self.root)

    def test_rejects_empty_report(self):
        with self.assertRaises(ValueError):
            evaluate({"data": []}, self.root)

    def test_ui_counts_in_overall_gate(self):
        self.entries[2]["summary"]["lines"]["count"] = 1000
        self.assertFalse(evaluate(self.report(), self.root)[0])

    def test_toast_view_and_presenter_keep_separate_coverage_contracts(self):
        for name, count, covered in [("Toast.swift", 10, 0), ("ToastPresenter.swift", 100, 100)]:
            path = self.root / name
            path.touch()
            self.entries.append({"filename": str(path), "summary": {"lines": {"count": count, "covered": covered}}})
        self.assertTrue(evaluate(self.report(), self.root)[0])
        self.entries[-1]["summary"]["lines"]["covered"] = 0
        self.assertFalse(evaluate(self.report(), self.root)[0])
        self.entries[-1]["summary"]["lines"]["covered"] = 100
        self.entries[-2]["summary"]["lines"]["count"] = 1000
        self.assertFalse(evaluate(self.report(), self.root)[0])

    def test_rejects_duplicate_entries(self):
        self.entries.append(self.entries[0])
        with self.assertRaises(ValueError):
            evaluate(self.report(), self.root)

    def test_editor_controls_are_ui_but_commands_keep_core_gate(self):
        for name, count, covered in [("NativeEditorControls.swift", 10, 0), ("EditorCommands.swift", 100, 100)]:
            path = self.root / name
            path.touch()
            self.entries.append({"filename": str(path), "summary": {"lines": {"count": count, "covered": covered}}})
        self.assertTrue(evaluate(self.report(), self.root)[0])
        self.entries[-1]["summary"]["lines"]["covered"] = 0
        self.assertFalse(evaluate(self.report(), self.root)[0])
        self.entries[-1]["summary"]["lines"]["covered"] = 100
        self.entries[-2]["summary"]["lines"]["count"] = 1000
        self.assertFalse(evaluate(self.report(), self.root)[0])

    def test_rejects_invalid_counts(self):
        self.entries[0]["summary"]["lines"]["covered"] = 101
        with self.assertRaises(ValueError):
            evaluate(self.report(), self.root)
