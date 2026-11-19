#!/usr/bin/env python3
"""使用两个已配置的同族 IP，在本机验证 GOST 的出口绑定和认证。"""

import argparse
import concurrent.futures
import contextlib
import ipaddress
import os
import pathlib
import socket
import subprocess
import tempfile
import threading
import time


USERS = {"alice": "alice-test", "bob": "bob-test", "unmapped": "unmapped-test"}


def receive(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError("SOCKS5 连接提前关闭")
        data += chunk
    return data


def address(ip, port):
    value = ipaddress.ip_address(ip)
    kind = b"\x01" if value.version == 4 else b"\x04"
    return kind + value.packed + port.to_bytes(2, "big")


def read_address(sock, kind):
    if kind == 1:
        host = str(ipaddress.IPv4Address(receive(sock, 4)))
    elif kind == 4:
        host = str(ipaddress.IPv6Address(receive(sock, 16)))
    elif kind == 3:
        host = receive(sock, receive(sock, 1)[0]).decode("ascii")
    else:
        raise AssertionError(f"未知地址类型: {kind}")
    return host, int.from_bytes(receive(sock, 2), "big")


def authenticate(sock, user, password):
    sock.sendall(b"\x05\x01\x02")
    assert receive(sock, 2) == b"\x05\x02", "服务没有要求密码认证"
    user, password = user.encode(), password.encode()
    sock.sendall(bytes((1, len(user))) + user + bytes((len(password),)) + password)
    return receive(sock, 2)[1] == 0


@contextlib.contextmanager
def proxy(binary, mode, first, second, family, policy=None):
    with tempfile.TemporaryDirectory() as directory:
        directory = pathlib.Path(directory)
        with socket.socket(family, socket.SOCK_STREAM) as reservation:
            reservation.bind((first, 0))
            port = reservation.getsockname()[1]
        auths = "".join(f"  - username: {u}\n    password: {p}\n" for u, p in USERS.items())
        services = []
        for index, host in enumerate((first, second) if mode == "ingress" else (first,)):
            host = f"[{host}]" if family == socket.AF_INET6 else host
            services.append(f'''- name: test-{index}
  addr: "{host}:{port}"
  listener:
    type: tcp
  handler:
    type: socks5
    auther: test-auth
    metadata:
      udp: true
      bind: true
''')
        config = directory / "config.yaml"
        config.write_text("services:\n" + "".join(services) + f'''authers:
- name: test-auth
  auths:
{auths}''', encoding="utf-8")
        env = os.environ.copy()
        for key in ("SOCKS5_ROUTE_CHECK", "SOCKS5_ROUTE_FILE"):
            env.pop(key, None)
        if mode != "default":
            policy_file = directory / "routes.conf"
            text = mode + "\n"
            if mode == "username":
                text += f"alice={first}\nbob={second}\n"
            policy_file.write_text(policy if policy is not None else text, encoding="utf-8")
            env["SOCKS5_ROUTE_FILE"] = str(policy_file)
        with (directory / "gost.log").open("w+") as log:
            proc = subprocess.Popen([binary, "-C", str(config)], env=env, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while True:
                    if proc.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("测试代理未能启动")
                    try:
                        with socket.create_connection((first, port), timeout=0.2):
                            break
                    except OSError:
                        time.sleep(0.05)
                yield port
            except Exception:
                log.seek(0)
                print(log.read())
                raise
            finally:
                proc.terminate()
                proc.wait(timeout=10)


@contextlib.contextmanager
def observer(family, local_ip, udp=False):
    with socket.socket(family, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM) as server:
        server.bind((local_ip, 0))
        server.settimeout(0.2)
        if not udp:
            server.listen(32)
        stop = threading.Event()

        def serve():
            while not stop.is_set():
                try:
                    if udp:
                        data, peer = server.recvfrom(2048)
                        if data == b"probe":
                            server.sendto(peer[0].encode(), peer)
                    else:
                        client, peer = server.accept()
                        with client:
                            client.sendall(peer[0].encode() + b"\n")
                except socket.timeout:
                    pass

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        try:
            yield server.getsockname()[1]
        finally:
            stop.set()
            worker.join()


def request(entry, port, user, command, payload, should_fail=False, expect_status=None):
    client = socket.create_connection((entry, port), timeout=5)
    try:
        assert authenticate(client, user, USERS[user]), "有效凭据被拒绝"
        client.sendall(bytes((5, command, 0)) + payload)
        version, status, _, kind = receive(client, 4)
        assert version == 5
        if should_fail:
            assert status != 0, "不满足出口策略的请求不应成功"
        else:
            assert status == 0, f"SOCKS5 请求失败，状态码 {status}"
        if expect_status is not None:
            assert status == expect_status, f"SOCKS5 状态码 {status}，期望 {expect_status}"
        return client, read_address(client, kind)
    except BaseException:
        client.close()
        raise


def tcp(entry, port, user, target, expected):
    client, _ = request(entry, port, user, 1, target)
    with client, client.makefile("rb") as reply:
        actual = reply.readline().decode().strip()
        assert actual, "接收端没有返回源地址"
        if expected:
            assert ipaddress.ip_address(actual) == ipaddress.ip_address(expected), (user, entry, actual, expected)


def udp(family, entry, port, user, target, expected):
    with socket.socket(family, socket.SOCK_DGRAM) as client:
        client.bind((entry, 0))
        client.settimeout(5)
        control, relay = request(entry, port, user, 3, address(*client.getsockname()[:2]))
        with control:
            if ipaddress.ip_address(relay[0]).is_unspecified:
                relay = (entry, relay[1])
            client.sendto(b"\x00\x00\x00" + target + b"probe", relay)
            payload = client.recv(2048)
            assert payload[:3] == b"\x00\x00\x00", "无效 UDP 封装"
            offset = {1: 10, 4: 22}[payload[3]]
            actual = payload[offset:].decode()
            assert ipaddress.ip_address(actual) == ipaddress.ip_address(expected), (user, entry, actual, expected)


def check_policy(binary, first, second):
    with tempfile.TemporaryDirectory() as directory:
        policy = pathlib.Path(directory) / "routes.conf"
        env = dict(os.environ, SOCKS5_ROUTE_FILE=str(policy), SOCKS5_ROUTE_CHECK="1")
        cases = [
            (f"username\nalice={first}\nbob={second}\n", True),
            (f"username\n  alice = {first}\n  bob = {second}\n", True),
            ("ingress\n", True),
            (f"username\nalice={first}\nalice={second}\n", False),
            ("username\nalice=not-an-ip\n", False),
            ("username\nalice=192.0.2.123\n", False),
            (f"ingress\nalice={first}\n", False),
        ]
        for text, valid in cases:
            policy.write_text(text, encoding="utf-8")
            result = subprocess.run([binary], env=env, timeout=10, capture_output=True)
            assert (result.returncode == 0) == valid, (text, result.stdout, result.stderr)
    print("通过: 策略校验")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", help="编译后的 gost-routed 路径")
    parser.add_argument("--stock", help="可选：原版 GOST 路径，用来额外验证默认模式")
    parser.add_argument("--ip-a", default="127.0.0.1")
    parser.add_argument("--ip-b", default="127.0.0.2")
    parser.add_argument("--stock-only", action="store_true", help="只验证传入二进制的默认模式")
    parser.add_argument("--separate-observers", action="store_true",
                        help="各出口使用同地址接收端；适合禁止跨接口访问的本机环境")
    args = parser.parse_args()
    a, b = (str(ipaddress.ip_address(ip)) for ip in (args.ip_a, args.ip_b))
    version = ipaddress.ip_address(a).version
    if a == b or ipaddress.ip_address(b).version != version:
        parser.error("需提供两个不同的同族 IP")
    family = socket.AF_INET if version == 4 else socket.AF_INET6
    binary = str(pathlib.Path(args.binary).resolve())
    for ip in (a, b):
        with socket.socket(family, socket.SOCK_STREAM) as bound:
            bound.bind((ip, 0))
    if not args.stock_only:
        check_policy(binary, a, b)
    with contextlib.ExitStack() as stack:
        def targets_for(ip):
            return (ip, stack.enter_context(observer(family, ip)),
                    stack.enter_context(observer(family, ip, udp=True)))

        targets_a = targets_for(a)
        targets_b = targets_for(b) if args.separate_observers else targets_a
        _, tcp_port, _ = targets_a
        modes = ("default",) if args.stock_only else ("default", "username", "ingress")
        for mode in modes:
            with proxy(binary, mode, a, b, family) as port:
                with socket.create_connection((a, port), timeout=5) as conn:
                    conn.sendall(b"\x05\x01\x00")
                    # rc10 即使未公布密码方法，也可能选用它；不能选无认证。
                    assert receive(conn, 2) in (b"\x05\xff", b"\x05\x02"), "无密码请求竟被接受"
                with socket.create_connection((a, port), timeout=5) as conn:
                    assert not authenticate(conn, "alice", "wrong"), "错误密码竟被接受"
                target = address(a, tcp_port)
                if mode == "default":
                    tcp(a, port, "alice", target, None)
                    print("通过: default")
                    continue
                cases = [(a, "alice", a), (a, "bob", b)] if mode == "username" else [(a, "alice", a), (b, "alice", b)]
                with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                    checks = []
                    for entry, user, expected in cases * 8:
                        host, target_port, _ = targets_a if expected == a else targets_b
                        checks.append(pool.submit(tcp, entry, port, user, address(host, target_port), expected))
                    for entry, user, expected in cases:
                        host, target_port, _ = targets_a if expected == a else targets_b
                        if host in ("127.0.0.1", "::1"):
                            domain = b"\x03\x09localhost" + target_port.to_bytes(2, "big")
                            checks.append(pool.submit(tcp, entry, port, user, domain, expected))
                    for check in checks:
                        check.result()
                for entry, user, expected in cases:
                    host, _, target_port = targets_a if expected == a else targets_b
                    udp(family, entry, port, user, address(host, target_port), expected)
                client, _ = request(a, port, "alice", 2, address(a, 0), should_fail=True)
                client.close()
                if mode == "username":
                    client, _ = request(a, port, "unmapped", 1, target, should_fail=True)
                    client.close()
                # 另一地址族即使有可达目标，也不能改用系统默认源地址。
                opposite = socket.AF_INET6 if family == socket.AF_INET else socket.AF_INET
                opposite_ip = "::1" if version == 4 else "127.0.0.1"
                if socket.has_ipv6:
                    with observer(opposite, opposite_ip) as opposite_port:
                        client, _ = request(a, port, "alice", 1, address(opposite_ip, opposite_port),
                                            should_fail=True, expect_status=8)
                        client.close()
            print(f"通过: {mode}")
        if not args.stock_only:
            # 缩进和等号两侧空白的映射必须与紧凑写法等价。
            spaced = f"username\n  alice = {a}\n  bob = {b}\n"
            with proxy(binary, "username", a, b, family, policy=spaced) as port:
                tcp(a, port, "alice", address(a, tcp_port), a)
            print("通过: 用户名映射容忍空白")
        if args.stock:
            with proxy(str(pathlib.Path(args.stock).resolve()), "default", a, b, family) as port:
                tcp(a, port, "alice", address(a, tcp_port), None)
                with socket.create_connection((a, port), timeout=5) as conn:
                    conn.sendall(b"\x05\x01\x00")
                    assert receive(conn, 2) in (b"\x05\xff", b"\x05\x02")
                with socket.create_connection((a, port), timeout=5) as conn:
                    assert not authenticate(conn, "alice", "wrong")
            print("通过: stock default")


if __name__ == "__main__":
    main()
