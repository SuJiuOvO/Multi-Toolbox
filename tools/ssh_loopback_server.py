"""127.0.0.1-only disposable SSH fixture. Requires paramiko, never production use.

Run: python tools/ssh_loopback_server.py --output <temporary-json-path>
The output JSON contains temporary test-only private keys. Delete it afterwards.
"""

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import socket
import threading

import paramiko


class FixtureServer(paramiko.ServerInterface):
    def __init__(self, authorized_key):
        self.authorized_key = authorized_key
        self.ready = threading.Event()
        self.pty = None

    def get_allowed_auths(self, username):
        return "password,publickey"

    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if (username, password) == ("toolbox-test", "loopback-password") else paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == "toolbox-test" and key == self.authorized_key else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, channel, term, width, height, pixelwidth, pixelheight, modes):
        self.pty = (width, height)
        return True

    def check_channel_window_change_request(self, channel, width, height, pixelwidth, pixelheight):
        channel.send(f"RESIZE:{width}x{height}\r\n".encode())
        return True

    def check_channel_shell_request(self, channel):
        self.ready.set()
        return True


def handle(connection, host_key, authorized_key):
    transport = paramiko.Transport(connection)
    try:
        transport.add_server_key(host_key)
        server = FixtureServer(authorized_key)
        transport.start_server(server=server)
        channel = transport.accept(10)
        if channel is None or not server.ready.wait(10):
            return
        channel.send(f"READY:{server.pty[0]}x{server.pty[1]}\r\n".encode())
        pending = b""
        while transport.is_active():
            data = channel.recv(32768)
            if not data:
                break
            pending += data
            while b"\n" in pending:
                command, pending = pending.split(b"\n", 1)
                if command == b"exit":
                    channel.send_exit_status(0)
                    channel.close()
                    return
                channel.send(b"ECHO:" + command.rstrip(b"\r") + b"\r\n")
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        transport.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    host_key = paramiko.RSAKey.generate(2048)
    authorized_key = paramiko.RSAKey.generate(2048)
    unencrypted = io.StringIO()
    encrypted = io.StringIO()
    authorized_key.write_private_key(unencrypted)
    authorized_key.write_private_key(encrypted, password="loopback-passphrase")
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        output = {
            "port": listener.getsockname()[1],
            "fingerprint": "SHA256:" + base64.b64encode(hashlib.sha256(host_key.asbytes()).digest()).decode().rstrip("="),
            "privateKey": unencrypted.getvalue(),
            "encryptedKey": encrypted.getvalue(),
        }
        arguments.output.write_text(json.dumps(output), encoding="utf-8")
        print(f"READY 127.0.0.1:{output['port']}", flush=True)
        while True:
            connection, _ = listener.accept()
            threading.Thread(target=handle, args=(connection, host_key, authorized_key), daemon=True).start()


if __name__ == "__main__":
    main()
