"""会话恢复：命令矩阵、注入防护、cwd 解析、终端打开——不触碰真实终端与剪贴板。"""
import json
import os
import tempfile
import unittest
from unittest.mock import patch

from tokentracker import resume


class ArgvTest(unittest.TestCase):
    def test_command_matrix(self):
        self.assertEqual(resume.resume_argv("claude", "abc"), ["claude", "--resume", "abc"])
        self.assertEqual(resume.resume_argv("codex", "abc"), ["codex", "resume", "abc"])
        self.assertEqual(resume.resume_argv("kimi", "abc"), ["kimi", "--session", "abc"])
        self.assertEqual(resume.resume_argv("opencode", "s1"), ["opencode", "--session", "s1"])
        self.assertEqual(resume.resume_argv("pi", "abc"), ["pi", "--session", "abc"])
        self.assertEqual(resume.resume_argv("hermes", "s1"), ["hermes", "--resume", "s1"])

    def test_unsupported_tool_and_missing_id(self):
        self.assertIsNone(resume.resume_argv("dsh", "session-x"))
        self.assertIsNone(resume.resume_argv("nope", "x"))
        self.assertIsNone(resume.resume_argv("claude", ""))


class ShellLineTest(unittest.TestCase):
    def test_quotes_hostile_values(self):
        import shlex
        evil = '$(touch /tmp/pwned)";`id`'
        with patch.object(resume.shutil, "which", return_value="/usr/bin/x"):
            cmd, reason = resume.shell_line("claude", evil, "/nonexistent-dir-xyz")
        self.assertIsNone(reason)
        self.assertIn(shlex.quote(evil), cmd)
        self.assertNotIn("cd ", cmd)   # 目录不存在时不加 cd

    def test_cds_into_existing_project(self):
        with tempfile.TemporaryDirectory() as d, \
                patch.object(resume.shutil, "which", return_value="/usr/bin/x"):
            cmd, _ = resume.shell_line("codex", "abc", d)
        self.assertTrue(cmd.startswith("cd "))
        self.assertIn("codex resume abc", cmd)

    def test_missing_cli_reports_reason(self):
        with patch.object(resume.shutil, "which", return_value=None):
            cmd, reason = resume.shell_line("claude", "abc", "")
        self.assertIsNone(cmd)
        self.assertIn("claude", reason)

    def test_dsh_is_not_resumable(self):
        cmd, reason = resume.shell_line("dsh", "session-x", "/tmp")
        self.assertIsNone(cmd)
        self.assertIn("不支持", reason)

    def test_cwd_override_wins_when_directory_exists(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b, \
                patch.object(resume.shutil, "which", return_value="/usr/bin/x"):
            cmd, _ = resume.shell_line("codex", "abc", a, cwd_override=b)
        self.assertIn(f"cd {b}", cmd)

    def test_claude_reads_cwd_from_jsonl(self):
        with tempfile.TemporaryDirectory() as root:
            proj = os.path.join(root, "-Users-x-proj")
            os.makedirs(proj)
            real = tempfile.mkdtemp()
            with open(os.path.join(proj, "sid-1.jsonl"), "w", encoding="utf-8") as f:
                f.write(json.dumps({"cwd": real}) + "\n")
            cwd = resume.resolve_cwd("claude", "sid-1", "-Users-x-proj", claude_root=root)
            self.assertEqual(cwd, real)

    def test_claude_slug_fallback_when_jsonl_absent(self):
        with tempfile.TemporaryDirectory() as root:
            cwd = resume.resolve_cwd("claude", "missing-id", "-nonexistent-xyz-abc",
                                     claude_root=root)
            self.assertIsNone(cwd)   # slug 还原的 /nonexistent/xyz/abc 不存在 → None


class InfoTest(unittest.TestCase):
    def test_unsupported(self):
        payload = resume.info("dsh", "session-x", "/tmp")
        self.assertFalse(payload["ok"])
        self.assertIn("不支持", payload["reason"])

    def test_missing_cli(self):
        with patch.object(resume.shutil, "which", return_value=None):
            payload = resume.info("claude", "abc", "")
        self.assertFalse(payload["ok"])
        self.assertIn("claude", payload["reason"])

    def test_ok_with_cwd_flag(self):
        with patch.object(resume.shutil, "which", return_value="/usr/bin/x"), \
                tempfile.TemporaryDirectory() as d:
            payload = resume.info("codex", "abc", d)
            self.assertTrue(payload["ok"])
            self.assertFalse(payload["cwd_missing"])
            payload = resume.info("codex", "abc", "/nonexistent-xyz")
            self.assertTrue(payload["ok"])
            self.assertTrue(payload["cwd_missing"])


class TerminalTest(unittest.TestCase):
    def test_pick_terminal_fallback(self):
        with patch.object(resume, "_app_installed", return_value=False):
            self.assertEqual(resume.pick_terminal("auto"), "terminal")
            self.assertEqual(resume.pick_terminal("iterm"), "terminal")
        with patch.object(resume, "_app_installed", side_effect=lambda n: n == "iTerm"):
            self.assertEqual(resume.pick_terminal("auto"), "iterm")
            self.assertEqual(resume.pick_terminal("wezterm"), "terminal")

    def test_applescript_escaping(self):
        self.assertEqual(resume._applescript_escape('a"b\\c'), 'a\\"b\\\\c')

    def test_open_terminal_uses_osascript(self):
        calls = []
        def fake_run(args, **kwargs):
            calls.append(args)
        with patch.object(resume, "pick_terminal", return_value="terminal"):
            self.assertTrue(resume.open_terminal("cd /tmp && claude --resume x", run=fake_run))
        self.assertEqual(calls[0][:2], ["osascript", "-e"])
        self.assertIn("do script", calls[0][2])

    def test_open_terminal_failure_returns_false(self):
        def boom(*a, **k):
            raise OSError("no osascript")
        with patch.object(resume, "pick_terminal", return_value="terminal"):
            self.assertFalse(resume.open_terminal("cmd", run=boom))

    def test_clipboard(self):
        seen = {}
        def fake_run(args, input=None, **kwargs):
            seen["args"] = args
            seen["input"] = input
        self.assertTrue(resume.copy_to_clipboard("echo hi", run=fake_run))
        self.assertEqual(seen["args"], ["pbcopy"])
        self.assertEqual(seen["input"], b"echo hi")
        self.assertFalse(resume.copy_to_clipboard("x", run=lambda *a, **k: (_ for _ in ()).throw(OSError())))


if __name__ == "__main__":
    unittest.main()
