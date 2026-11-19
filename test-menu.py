#!/usr/bin/env python3
"""用临时安装和替身命令测试 socks5 菜单：python3 test-menu.py。"""

import errno
import os
import pathlib
import re
import select
import shutil
import subprocess
import tempfile
import time
import unittest


INSTALLER = pathlib.Path(__file__).with_name("install.sh")
WINDOWS = os.name == "nt"
TIMEOUT = 20
ALICE = "alice:fixture-alice-secret"
PORT = "10842"
PUBLIC_IP = "192.0.2.42"


def find_bash():
    if os.environ.get("BASH"):
        return os.environ["BASH"]
    if WINDOWS:
        for key in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"):
            base = os.environ.get(key)
            if base:
                candidate = pathlib.Path(base) / "Git" / "bin" / "bash.exe"
                if candidate.is_file():
                    return str(candidate)
    return shutil.which("bash")


class MenuTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        bash = find_bash()
        if not bash:
            raise RuntimeError("需要 Bash；Windows 可设置 BASH 为 Git Bash 的绝对路径")
        cls.bash = [bash, "--noprofile", "--norc"]
        cls.installer = INSTALLER.read_text(encoding="utf-8")

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="socks5-menu-")
        self.addCleanup(directory.cleanup)
        self.root = pathlib.Path(directory.name)
        self.env = dict(os.environ, LC_ALL="C", TERM="dumb")
        for key in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "CDPATH",
                    "BASH_XTRACEFD", "SOCKS5_ROUTE_CHECK", "SOCKS5_ROUTE_FILE"):
            self.env.pop(key, None)
        # 不从主机 PATH 查找服务/防火墙工具；Git Bash 的工具在 /usr/bin。
        self.system_path = "/usr/bin:/bin"
        self.env["TEST_PATH"] = self.system_path
        self.base = self.run_bash(["-c", "pwd -P"]).stdout.strip()
        if not self.base.startswith("/") or any(c in self.base for c in '"$`\\\n'):
            self.fail(f"无法安全地替换临时目录路径：{self.base!r}")
        self.env["TEST_PATH"] = f"{self.base}/mock:{self.system_path}"
        self.config = self.root / "config"
        self.config.mkdir()
        self.bindir = self.root / "bin"
        self.bindir.mkdir()
        self.mocks = self.root / "mock"
        self.mocks.mkdir()
        self.users = self.config / "users.txt"
        self.yaml = self.config / "config.yaml"
        self.routes = self.config / "routes.conf"
        self.unit = self.root / "service"
        self.events = self.root / "events"
        self.command = self.bindir / "socks5"
        self.write(self.users, ALICE + "\n")
        self.write(self.unit, f"[Service]\nExecStart={self.base}/bin/socks5 _serve\n")
        self.write(self.root / "installer", self.isolate(self.installer))
        # 只加载安装器函数来生成 CLI，绝不运行安装器的默认安装入口。
        functions, marker, _ = self.installer.partition("# ============ 入口 ============")
        self.assertTrue(marker, "找不到安装器入口；拒绝加载完整安装器")
        self.write(self.root / "functions", self.isolate(functions))
        self.mock_system()
        made = self.run_bash(["-c", '. ./functions; write_socks5_cmd ./bin/socks5'])
        self.assertEqual(made.returncode, 0, made.stderr)
        generated = self.cli("_generate", PORT, "config/users.txt")
        self.assertEqual(generated.returncode, 0, generated.stderr)
        self.write(self.yaml, generated.stdout)

    @staticmethod
    def write(path, text):
        path.write_text(text, encoding="utf-8", newline="\n")

    def isolate(self, text):
        for original, fixture in (
            ("/usr/local/bin", "/bin"),
            ("/etc/socks5", "/config"),
            ('/etc/systemd/system/${SERVICE_NAME}.service', "/service"),
            ("/etc/iptables.rules", "/iptables.rules"),
        ):
            text = text.replace(original, self.base + fixture)
        # 测试以普通用户运行；仅替换 root 检查，不修改受测分派或业务逻辑。
        text = text.replace("[[ $EUID -eq 0 ]]", ":")
        return text

    def mock_system(self):
        def command(name, body, directory=None):
            path = (directory or self.mocks) / name
            self.write(path, "#!/bin/bash\n" + body + "\n")
            path.chmod(0o755)

        command("systemctl", '''printf 'systemctl %s\n' "$*" >> events
case "$1" in
    status) echo fixture-service-status; [[ -e active ]] || exit 3 ;;
    start|restart)
        if [[ -e fail-next-start ]]; then rm -- fail-next-start; exit 1; fi
        : > active ;;
    stop) rm -f -- active ;;
    is-active)
        if [[ "${*: -1}" == socks5-proxy && -e active ]]; then state=active; else state=inactive; fi
        if [[ "${2:-}" != --quiet ]]; then echo "$state"; fi
        [[ "$state" == active ]] || exit 3 ;;
    show) echo MainPID=4242 ;;
    disable|daemon-reload) : ;;
    *) exit 99 ;;
esac''')
        command("ss", '''printf 'ss %s\n' "$*" >> events
if [[ -e active ]]; then
    printf 'LISTEN 0 64 0.0.0.0:10842 0.0.0.0:* users:(("gost",pid=4242,fd=3))\n'
fi''')
        command("curl", f"printf 'curl %s\\n' \"$*\" >> events\necho {PUBLIC_IP}")
        command("journalctl", '''printf 'journalctl %s\\n' "$*" >> events
echo fixture-log-line''')
        # Git Bash 没有 flock；单进程用例只记录加锁调用。
        command("flock", "printf 'flock %s\\n' \"$*\" >> events")
        for firewall in ("ufw", "firewall-cmd", "iptables", "iptables-save"):
            command(firewall, f"printf '{firewall} %s\\n' \"$*\" >> events\nexit 1")
        for backend in ("gost", "gost-routed"):
            command(backend, f'''printf '{backend} %s %s %s\\n' "${{SOCKS5_ROUTE_CHECK:-}}" "${{SOCKS5_ROUTE_FILE:-}}" "$*" >> events
if [[ "$1" == -V ]]; then
    [[ "${{SOCKS5_ROUTE_CHECK:-}}" == 1 && -r "${{SOCKS5_ROUTE_FILE:-}}" ]] || exit 77
    if grep -Fq invalid "$SOCKS5_ROUTE_FILE"; then echo fixture-invalid-route >&2; exit 78; fi
fi''', self.bindir)

    def bash_args(self, args):
        return self.bash + ["-c", 'export PATH="$TEST_PATH"; exec /bin/bash "$@"', "--", *args]

    def run_bash(self, args, data=""):
        result = subprocess.run(self.bash_args(args), cwd=self.root, env=self.env,
                                input=data.encode(), capture_output=True, timeout=TIMEOUT)
        return subprocess.CompletedProcess(result.args, result.returncode,
                                           result.stdout.decode().replace("\r\n", "\n"),
                                           result.stderr.decode().replace("\r\n", "\n"))

    def cli(self, *args, data=""):
        return self.run_bash(["./bin/socks5", *args], data)

    def log(self):
        return self.events.read_text(encoding="utf-8") if self.events.exists() else ""

    def menu(self, data, *args, exchange=()):
        if WINDOWS:
            # Windows Python 没有 POSIX PTY。只模拟 -t 谓词，保留原 read 和菜单分派。
            source = self.command.read_text(encoding="utf-8")
            source, replacements = re.subn(r"-t\s+[01]\b", '-n "${TEST_TTY:-}"', source)
            self.assertGreaterEqual(replacements, 2, "未找到菜单的 TTY 谓词")
            if any("密码" in prompt for prompt, _ in exchange):
                self.assertRegex(source, r'read\s+-[a-z]*s[a-z]*\s+"密码')
            script = self.bindir / "socks5-test-tty"
            self.write(script, source)
            self.env["TEST_TTY"] = "1"
            result = self.run_bash(["./bin/socks5-test-tty", *args],
                                   "".join(reply for _, reply in exchange) + data)
            return result.returncode, result.stdout + result.stderr
        return self.pty_run(data, args, exchange)

    def pty_run(self, data, args, exchange):
        from pty import openpty
        from termios import ECHO, tcgetattr

        master, slave = openpty()
        try:
            process = subprocess.Popen(self.bash_args(["./bin/socks5", *args]),
                                       cwd=self.root, env=self.env, stdin=slave,
                                       stdout=slave, stderr=slave, start_new_session=True)
        finally:
            os.close(slave)
        output = bytearray()
        deadline = time.monotonic() + TIMEOUT

        def receive():
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([master], [], [], remaining)[0]:
                self.fail(f"菜单终端超时：{output.decode(errors='replace')}")
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:  # Linux PTY 的 EOF
                    return False
                raise
            output.extend(chunk)
            return bool(chunk)

        try:
            offset = 0
            for prompt, reply in exchange:
                marker = prompt.encode()
                while output.find(marker, offset) < 0:
                    self.assertTrue(receive(), output.decode(errors="replace"))
                offset = output.index(marker, offset) + len(marker)
                if "密码" in prompt:
                    # Bash 可能先打印提示，再关闭终端回显。
                    echo_deadline = time.monotonic() + 1
                    while tcgetattr(master)[3] & ECHO:
                        self.assertLess(time.monotonic(), echo_deadline, "密码输入仍开启终端回显")
                        time.sleep(0.005)
                os.write(master, reply.encode())
            if data:
                os.write(master, data.encode())
            while receive():
                pass
            return process.wait(timeout=TIMEOUT), output.decode().replace("\r\n", "\n")
        finally:
            os.close(master)
            if process.poll() is None:
                process.kill()
                process.wait()

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_menu_ok(self, data, *args, exchange=()):
        status, output = self.menu(data, *args, exchange=exchange)
        self.assertEqual(status, 0, output)
        return output

    def test_noninteractive_help_and_menu_rejection(self):
        for args in ((), ("help",)):
            with self.subTest(args=args):
                result = self.cli(*args, data="10\ny\n")
                self.assert_ok(result)
                self.assertIn("socks5 status", result.stdout)
                self.assertIn("socks5 menu", result.stdout)
        rejected = self.cli("menu", data="10\ny\n")
        self.assertNotEqual(rejected.returncode, 0)
        self.assertRegex(rejected.stdout + rejected.stderr, r"终端|TTY")
        self.assertEqual(self.log(), "")
        self.assertTrue(self.command.exists())

    @unittest.skipIf(WINDOWS, "需要将 PTY 和管道分别连接到命令")
    def test_menu_rejects_when_only_one_stream_is_a_terminal(self):
        from pty import openpty

        master, slave = openpty()
        try:
            for tty_stdin in (True, False):
                with self.subTest(tty_stdin=tty_stdin):
                    settings = {"stdin": slave, "stdout": subprocess.PIPE} if tty_stdin else {
                        "input": b"0\n", "stdout": slave}
                    result = subprocess.run(self.bash_args(["./bin/socks5", "menu"]),
                                            cwd=self.root, env=self.env, stderr=subprocess.PIPE,
                                            timeout=TIMEOUT, **settings)
                    self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.log(), "")
        finally:
            os.close(master)
            os.close(slave)

    def test_interactive_entry_invalid_choice_and_eof(self):
        for args in ((), ("menu",)):
            with self.subTest(args=args):
                output = self.assert_menu_ok("not-an-option\n0\n", *args)
                self.assertIn("SOCKS5", output)
                self.assertGreaterEqual(len(re.findall(r"(?m)^\s*10[.)、]", output)), 2)
        self.assert_menu_ok("" if WINDOWS else "\x04", "menu")

    def test_menu_status_and_service_actions(self):
        output = self.assert_menu_ok("1\n4\ny\n6\ny\n5\ny\n0\n")
        self.assertIn("fixture-service-status", output)
        self.assertIn(PORT, output)
        self.assertNotIn("操作失败", output)
        calls = [line.split()[1] for line in self.log().splitlines()
                 if line.startswith("systemctl ") and line.split()[1] in ("status", "start", "restart", "stop")]
        self.assertEqual(calls, ["status", "start", "restart", "stop"])
        self.assertIn(f"ss -H -ltnp sport = :{PORT}", self.log())
        self.assertFalse((self.root / "active").exists())

    def test_menu_service_failure_can_be_retried(self):
        self.write(self.root / "fail-next-start", "")
        output = self.assert_menu_ok("4\ny\n1\ny\n0\n")
        self.assertIn("操作失败", output)
        self.assertIn("1) 重试", output)
        self.assertEqual(self.log().count("systemctl start socks5-proxy"), 2)
        self.assertEqual(self.log().count("ss -H -ltnp"), 1)
        self.assertTrue((self.root / "active").exists())

    def test_menu_info_and_user_list_have_different_disclosure(self):
        listing = self.assert_menu_ok("3\n0\n")
        self.assertRegex(listing, r"\balice\b")
        self.assertNotIn(ALICE.split(":")[1], listing)
        self.assertNotIn("socks5://", listing)
        self.assertNotIn("curl", self.log())
        details = self.assert_menu_ok("2\n0\n")
        self.assertIn(f"socks5://{ALICE}@{PUBLIC_IP}:{PORT}", details)

    def test_menu_add_confirmation_and_password_input(self):
        password = "fixture-bob-do-not-echo"
        exchange = (("请选择 [0-13]:", "7\n"), ("用户名", "bob\n"), ("密码", password + "\n"))
        canceled = self.assert_menu_ok("0\n", exchange=(*exchange, ("确认添加用户?", "\n")))
        self.assertNotIn(password, canceled)
        self.assertEqual(self.users.read_text(encoding="utf-8"), ALICE + "\n")
        self.assertNotIn("systemctl restart", self.log())
        confirmed = self.assert_menu_ok("0\n", exchange=(*exchange, ("确认添加用户?", "y\n")))
        self.assertNotIn(password, confirmed)
        self.assertEqual(self.users.read_text(encoding="utf-8"), f"{ALICE}\nbob:{password}\n")
        self.assertIn(f'password: "{password}"', self.yaml.read_text(encoding="utf-8"))
        self.assertIn("systemctl restart socks5-proxy", self.log())

    def test_menu_delete_and_stop_last_user(self):
        self.write(self.root / "active", "")
        original = self.yaml.read_bytes()
        self.assert_menu_ok("8\n1\nn\n0\n")
        self.assertEqual(self.users.read_text(encoding="utf-8"), ALICE + "\n")
        self.assertEqual(self.yaml.read_bytes(), original)
        self.assertNotIn("systemctl stop", self.log())
        self.assert_menu_ok("8\n1\ny\n0\n")
        self.assertEqual(self.users.read_bytes(), b"")
        self.assertIn("services: []", self.yaml.read_text(encoding="utf-8"))
        self.assertEqual(self.log().count("systemctl stop socks5-proxy"), 1)
        self.assertFalse((self.root / "active").exists())

    def test_menu_uninstall_cancel_then_confirm(self):
        before = self.yaml.read_bytes()
        self.assert_menu_ok("13\n\n0\n")
        self.assertEqual(self.yaml.read_bytes(), before)
        self.assertNotIn("systemctl disable", self.log())
        self.assertNotIn("systemctl stop", self.log())
        self.assert_menu_ok("13\ny\n0\n")
        for path in (self.config, self.command, self.unit, self.bindir / "gost", self.bindir / "gost-routed"):
            self.assertFalse(path.exists(), str(path))
        self.assertIn("systemctl disable socks5-proxy", self.log())
        self.assertIn("systemctl daemon-reload", self.log())

    def test_routes_show_ingress_and_default_while_inactive(self):
        self.assert_menu_ok("9\n2\n\n0\n0\n")
        self.assertFalse(self.routes.exists())
        self.assert_menu_ok("9\n2\ny\n0\n0\n")
        self.assertEqual(self.routes.read_text(encoding="utf-8"), "ingress\n")
        self.assertRegex(self.log(), r"gost-routed 1 .* -V")
        self.assertNotIn("systemctl restart", self.log())
        output = self.assert_menu_ok("9\n4\n0\n0\n")
        self.assertIn("ingress", output)
        (self.bindir / "gost-routed").unlink()
        self.assert_menu_ok("9\n1\ny\n0\n0\n")
        self.assertFalse(self.routes.exists())
        self.assertNotIn("systemctl restart", self.log())

    def test_routes_username_applies_when_service_active(self):
        self.write(self.root / "active", "")
        self.assert_menu_ok("9\n3\n192.0.2.87\ny\n0\n0\n")
        self.assertEqual(self.routes.read_text(encoding="utf-8"), "username\nalice=192.0.2.87\n")
        self.assertGreaterEqual(self.log().count("gost-routed 1 "), 2)
        self.assertIn("systemctl restart socks5-proxy", self.log())
        self.assertIn("ss -H -ltnp", self.log())
        self.assert_ok(self.cli("_serve"))
        self.assertIn(f"gost-routed  {self.base}/config/routes.conf -C", self.log())

    def test_routes_invalid_mapping_and_failed_restart_keep_previous_policy(self):
        self.write(self.routes, "ingress\n")
        output = self.assert_menu_ok("9\n3\ninvalid\n0\n0\n0\n")
        self.assertIn("fixture-invalid-route", output)
        self.assertEqual(self.routes.read_text(encoding="utf-8"), "ingress\n")
        self.assertNotIn("systemctl restart", self.log())
        self.write(self.root / "active", "")
        self.write(self.root / "fail-next-start", "")
        self.assert_menu_ok("9\n3\n192.0.2.87\ny\n0\n0\n0\n")
        self.assertEqual(self.routes.read_text(encoding="utf-8"), "ingress\n")
        self.assertTrue((self.root / "active").exists())
        self.assertIn("systemctl restart socks5-proxy", self.log())
        self.assertIn("ss -H -ltnp", self.log())  # 回滚也应验证旧服务恢复监听。

    def test_menu_logs_views_journal(self):
        output = self.assert_menu_ok("10\n1\n0\n0\n")
        self.assertIn("fixture-log-line", output)
        self.assertIn("journalctl -u socks5-proxy -n 50", self.log())

    def test_menu_port_change_validates_and_saves_when_inactive(self):
        output = self.assert_menu_ok("11\n99999\n20001\ny\n0\n")
        self.assertIn("20001", output)
        self.assertIn('addr: ":20001"', self.yaml.read_text(encoding="utf-8"))
        self.assertIn("sport = :20001", self.log())
        self.assertNotIn("systemctl restart", self.log())

    def test_menu_port_change_restarts_and_rolls_back(self):
        self.write(self.root / "active", "")
        self.assert_menu_ok("11\n20002\ny\n0\n")
        self.assertIn('addr: ":20002"', self.yaml.read_text(encoding="utf-8"))
        self.assertIn("systemctl restart socks5-proxy", self.log())
        self.write(self.root / "fail-next-start", "")
        self.assert_menu_ok("11\n20003\ny\n0\n0\n")
        self.assertIn('addr: ":20002"', self.yaml.read_text(encoding="utf-8"))
        self.assertTrue((self.root / "active").exists())

    def test_menu_upgrade_requires_local_installer(self):
        output = self.assert_menu_ok("12\n0\n")
        self.assertIn("未找到本地安装脚本", output)

    def test_menu_upgrade_rejects_relative_path_and_invokes_installer(self):
        self.write(self.config / "installer.sh", "#!/bin/bash\necho \"installer $*\" >> events\n")
        self.write(self.bindir / "gost-next", "")
        path = f"{self.base}/bin/gost-next"
        output = self.assert_menu_ok(f"12\nrelative\n{path}\ny\n0\n")
        self.assertIn("请输入绝对路径", output)
        self.assertIn(f"installer upgrade {path}", self.log())

    def test_legacy_commands_still_work_with_pipes(self):
        self.assertIn("fixture-service-status", self.cli("status").stdout)
        for verb in ("start", "restart", "stop"):
            self.assert_ok(self.cli(verb))
        for verb in ("info", "list"):
            result = self.cli(verb)
            self.assert_ok(result)
            self.assertIn(f"socks5://{ALICE}@{PUBLIC_IP}:{PORT}", result.stdout)
        self.assert_ok(self.cli("add", data="bob\nfixture-bob-secret\n"))
        self.assertIn("bob:fixture-bob-secret\n", self.users.read_text(encoding="utf-8"))
        self.assert_ok(self.cli("del", data="bob\n"))
        self.assertEqual(self.users.read_text(encoding="utf-8"), ALICE + "\n")
        self.assert_ok(self.cli("uninstall", data="n\n"))
        self.assertTrue(self.command.exists())
        self.assert_ok(self.cli("_serve"))
        self.assertIn(f"gost   -C {self.base}/config/config.yaml", self.log())

    def test_update_cli_changes_only_the_command(self):
        self.write(self.command, "#!/bin/bash\necho old-command\n")
        self.write(self.routes, "ingress\n")
        protected = (self.yaml, self.users, self.routes, self.unit, self.bindir / "gost", self.bindir / "gost-routed")
        before = [(p.read_bytes(), p.stat().st_mtime_ns) for p in protected]
        result = self.run_bash(["./installer", "update-cli"])
        self.assert_ok(result)
        self.assertNotIn("old-command", self.command.read_text(encoding="utf-8"))
        if not WINDOWS:
            self.assertEqual(self.command.stat().st_mode & 0o777, 0o755)
        self.assertIn("socks5 menu", self.cli("help").stdout)
        self.assertEqual([(p.read_bytes(), p.stat().st_mtime_ns) for p in protected], before)
        self.assertEqual(self.log().splitlines(), ["flock -x 9"])
        self.assertEqual(list(self.bindir.glob("socks5.update.*")), [])

    def test_update_cli_rejects_legacy_unit_and_invalid_port(self):
        self.write(self.command, "#!/bin/bash\necho unchanged-old-command\n")
        original = self.command.read_bytes()
        for path, content in ((self.unit, "[Service]\nExecStart=/usr/local/bin/gost\n"),
                              (self.yaml, '  addr: ":65536"\n')):
            with self.subTest(path=path.name):
                before = path.read_bytes()
                self.write(path, content)
                try:
                    result = self.run_bash(["./installer", "update-cli"])
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(self.command.read_bytes(), original)
                    self.assertEqual(list(self.bindir.glob("socks5.update.*")), [])
                    self.assertNotIn("systemctl", self.log())
                finally:
                    path.write_bytes(before)


if __name__ == "__main__":
    unittest.main()
