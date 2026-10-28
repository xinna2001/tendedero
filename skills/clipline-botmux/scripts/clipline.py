#!/usr/bin/env python3
"""Post literal text to ClipLine, then verify its durable application receipt."""
import argparse
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from install import ensure_app


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    data = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    fd, temporary = tempfile.mkstemp(prefix=".clipline-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(data)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return data


def ready(root):
    try:
        status = json.loads((root / "status.json").read_bytes())
        os.kill(status["pid"], 0)
        return status.get("app") == "ClipLine" and status.get("protocolVersion") == 1 and time.time() - status["updatedAt"] < 5
    except (OSError, ValueError, KeyError):
        return False


def ensure_running(args, root):
    with (root / "install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        app = ensure_app(args.install_root, args.app, args.source_app)
    if args.command == "install":
        return app
    if not ready(root):
        if args.no_launch:
            raise RuntimeError("指定数据目录下没有运行中的图绳应用。")
        if args.data_root:
            env = os.environ.copy(); env["CLIPLINE_DATA_ROOT"] = str(root)
            subprocess.Popen([str(app / "Contents/MacOS/ClipLine")], env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        else:
            subprocess.run(["open", "-g", str(app)], check=True)
        deadline = time.monotonic() + args.timeout
        while not ready(root):
            if time.monotonic() >= deadline:
                raise RuntimeError("图绳已请求启动，但联动接口还未就绪。")
            time.sleep(0.1)
    return app


def read_text(args):
    if args.text is not None:
        text = args.text
    elif args.content_file:
        text = Path(args.content_file).read_bytes().decode("utf-8")
    else:
        text = sys.stdin.buffer.read().decode("utf-8")
    if len(text.encode("utf-8")) > 1_000_000:
        raise RuntimeError("单条文字超过 1 MB。")
    return text


def send(root, operation, args, text=None):
    key = args.request_id
    try:
        request_id = str(uuid.UUID(key)) if key else str(uuid.uuid4())
    except ValueError:
        request_id = str(uuid.uuid5(uuid.NAMESPACE_URL, "clipline:" + key))
    request = {"version": 1, "id": request_id, "operation": operation}
    if text is not None:
        request["text"] = text
    if args.note_id:
        request["noteID"] = str(uuid.UUID(args.note_id))
    if args.revision is not None:
        request["expectedRevision"] = args.revision
    data = json.dumps(request, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    digest = hashlib.sha256(data).hexdigest()
    receipt_path = root / "Receipts" / (request_id + ".json")
    request_path = root / "Requests" / (request_id + ".json")
    with (root / "request.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not receipt_path.exists():
            if request_path.exists() and request_path.read_bytes() != data:
                raise RuntimeError("同一个请求 ID 已用于不同内容。")
            atomic_json(request_path, request)
    deadline = time.monotonic() + args.timeout
    while not receipt_path.exists():
        if time.monotonic() >= deadline:
            raise RuntimeError(f"请求已入队但还未收到应用回执；重试时保留请求 ID：{request_id}。")
        time.sleep(0.1)
    receipt = json.loads(receipt_path.read_bytes())
    if receipt.get("requestSHA256") != digest:
        raise RuntimeError("回执对应不同内容；不能复用这个请求 ID。")
    if not receipt.get("success"):
        raise RuntimeError(receipt.get("error", "图绳处理失败。"))
    result = {"success": True, "requestID": request_id, "shown": receipt.get("shown")}
    if note := receipt.get("note"):
        note_id = str(uuid.UUID(note["id"]))
        saved = json.loads((root / "Notes" / (note_id + ".clipnote")).read_bytes())
        if str(uuid.UUID(saved["id"])) != note_id or saved["revision"] < note["revision"]:
            raise RuntimeError("应用回执与本地便签读回不一致。")
        if note["text"] != text:
            raise RuntimeError("原请求对应的便签内容已改变；不会覆盖用户修改。")
        if saved["revision"] == note["revision"] and saved["text"] != text:
            raise RuntimeError("保存后的文字不一致。")
        result.update(noteID=note_id, revision=saved["revision"],
                      verified=True, bytes=len(text.encode()), contentSHA256=hashlib.sha256(text.encode()).hexdigest(),
                      editedSinceDelivery=saved["revision"] > note["revision"])
    if "notes" in receipt:
        result["notes"] = receipt["notes"]
    return result


def arm_path(root, args):
    if not args.session or not args.sender:
        raise RuntimeError("等待下一条消息需要明确的 Botmux session 和 sender。")
    key = hashlib.sha256((args.session + "\n" + args.sender).encode()).hexdigest()
    return root / "BotmuxArms" / (key + ".json")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["hang", "update", "show", "hide", "list", "install", "arm", "consume", "cancel", "status"])
    parser.add_argument("--content-file"); parser.add_argument("--text")
    parser.add_argument("--request-id"); parser.add_argument("--note-id"); parser.add_argument("--revision", type=int)
    parser.add_argument("--app"); parser.add_argument("--source-app"); parser.add_argument("--install-root")
    parser.add_argument("--data-root"); parser.add_argument("--no-launch", action="store_true")
    parser.add_argument("--session"); parser.add_argument("--sender")
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("图绳桌面应用需要 macOS 14 或以上。")
    root = Path(args.data_root).expanduser().resolve() if args.data_root else Path.home() / "Library/Application Support/ClipLine"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.command == "cancel":
        arm_path(root, args).unlink(missing_ok=True)
        return {"success": True, "armed": False}
    if args.command == "consume":
        path = arm_path(root, args)
        arm = json.loads(path.read_bytes())
        if time.time() - arm["armedAt"] > 600:
            raise RuntimeError("图绳等待下一条消息已过期，请重新说图绳。")
    app = ensure_running(args, root)
    if args.command == "install":
        return {"success": True, "app": str(app)}
    if args.command == "status":
        return json.loads((root / "status.json").read_bytes())
    if args.command == "arm":
        result = send(root, "line.show", args)
        atomic_json(arm_path(root, args), {"armedAt": time.time()})
        result["armed"] = True
        return result
    if args.command in ["hang", "consume", "update"]:
        if args.command == "update" and (not args.note_id or args.revision is None):
            raise RuntimeError("修改便签需要 note-id 和当前 revision。")
        result = send(root, "note.update" if args.command == "update" else "note.add", args, read_text(args))
        if args.command == "consume":
            arm_path(root, args).unlink(missing_ok=True)
        return result
    return send(root, {"show": "line.show", "hide": "line.hide", "list": "note.list"}[args.command], args)


if __name__ == "__main__":
    try:
        print(json.dumps(main(), ensure_ascii=False))
    except Exception as error:
        print(json.dumps({"success": False, "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
