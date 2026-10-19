#!/usr/bin/env python3
"""Gửi prompt "Báo cáo sức khoẻ AI" mẫu (ngày Y25 16/10/2026) tới LLM của runpod-ai rồi in JSON trả về.

Prompt lấy thẳng từ mã Swift (không chép tay, để khỏi lệch):
  - system prompt: `HealthReportPrompt.system` trong sdks/core/ios/Sources/SmartWearCore/HealthReportPrompt.swift
  - tin nhắn người dùng: `y25JSON` trong sdks/core/ios/Tests/SmartWearCoreTests/HealthReportTests.swift

Khoá đọc từ .secrets/llm.env (LLM_API_BASE, LLM_MODEL, LLM_API_KEY), KHÔNG bao giờ in ra.

  python3 sdks/core/tools/health_report_llm.py            # in JSON báo cáo + thời gian + số token
  python3 sdks/core/tools/health_report_llm.py --env path/llm.env
"""
import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PROMPT_SWIFT = ROOT / "sdks/core/ios/Sources/SmartWearCore/HealthReportPrompt.swift"
TESTS_SWIFT = ROOT / "sdks/core/ios/Tests/SmartWearCoreTests/HealthReportTests.swift"
# Cloudflare chặn UA Python-urllib (403, error code 1010): dùng UA kiểu trình duyệt như app.
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
      "Mobile/15E148 SmartWearLab/0.1")


def load_env(path: Path) -> dict:
    env = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[7:]
        k, v = line.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        env[k.strip()] = v
    return env


def swift_system_prompt() -> str:
    src = PROMPT_SWIFT.read_text(encoding="utf-8")
    body = re.search(r'public static let system = """\n(.*?)\n\s*"""', src, re.S).group(1)
    lines = [l[4:] if l.startswith("    ") else l for l in body.split("\n")]
    # Swift: "\" cuối dòng = nối dòng, không xuống dòng.
    out = ""
    for l in lines:
        out += l[:-1] if l.endswith("\\") else l + "\n"
    return out.rstrip("\n")


def swift_y25_json() -> str:
    src = TESTS_SWIFT.read_text(encoding="utf-8")
    return re.search(r'static let y25JSON =\s*#"(.*?)"#', src, re.S).group(1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default=str(ROOT / ".secrets/llm.env"))
    ap.add_argument("--max-tokens", type=int, default=900)
    args = ap.parse_args()

    env = load_env(Path(args.env))
    base, key = env.get("LLM_API_BASE", "").rstrip("/"), env.get("LLM_API_KEY", "")
    model = env.get("LLM_MODEL") or "Qwen/Qwen3.6-35B-A3B-FP8"
    if not base or not key:
        print("Chưa cấu hình máy chủ AI (thiếu LLM_API_BASE / LLM_API_KEY)", file=sys.stderr)
        return 2

    user = swift_y25_json()
    body = {
        "model": model,
        "messages": [{"role": "system", "content": swift_system_prompt()}, {"role": "user", "content": user}],
        "temperature": 0.3,
        "max_tokens": args.max_tokens,
        "response_format": {"type": "json_object"},
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(
        f"{base}/chat/completions", data=json.dumps(body, ensure_ascii=False).encode("utf-8"), method="POST",
        headers={"Content-Type": "application/json", "X-API-Key": key, "User-Agent": UA},
    )
    print(f"POST {base}/chat/completions  model={model}")
    print(f"user message ({len(user)} ký tự): {user}\n")
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            data = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        hint = {502: "Máy chủ AI đang khởi động lại, thử lại sau vài phút", 401: "Khoá sai hoặc hết hạn",
                403: "Khoá sai / Cloudflare chặn UA"}.get(e.code, "")
        print(f"HTTP {e.code} {hint}: {e.read()[:300].decode('utf-8', 'replace')}", file=sys.stderr)
        return 1
    elapsed = time.time() - started
    msg = data["choices"][0]["message"]
    content = (msg.get("content") or msg.get("reasoning_content") or "").strip()
    usage = data.get("usage", {})
    print(f"⏱ {elapsed:.1f} s · token vào {usage.get('prompt_tokens')} · ra {usage.get('completion_tokens')} · "
          f"finish={data['choices'][0].get('finish_reason')}\n")
    try:
        text = re.sub(r"^```\w*\s*|\s*```$", "", content)
        print(json.dumps(json.loads(text[text.index("{"):text.rindex("}") + 1]), ensure_ascii=False, indent=2))
    except (ValueError, json.JSONDecodeError):
        print("(không phải JSON, in nguyên văn)\n" + content)
    return 0


if __name__ == "__main__":
    sys.exit(main())
