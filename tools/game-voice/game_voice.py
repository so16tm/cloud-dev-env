"""Irodori-TTS v4.1 Small MF を ONNX INT8 で CPU 実行し、台詞の WAV を書き出す CLI。

so16tm/game-voice の ONNX INT8 方式から、生成・一括生成・参照音声・キャラクタープリセットだけを移植した。
推論フローの出所: kgmkm/muse-irodori-voice @ 2a41b614 (MIT, Copyright 2026 kgmkm)
ライセンス全文: LICENSE-muse-irodori-voice.txt
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUILTIN_PRESETS = HERE / "presets.json"
CACHE_DIR = Path(os.environ.get("GAME_VOICE_CACHE", HERE / "reference-cache"))

MODEL_REPO = "Ryoppi/Irodori-TTS-v4.1-Small-MF-ONNX-int8"
MODEL_REVISION = "0701bc6758cbb364a9577d5799a90a45baa8ffa2"
ENCODER_REPO = "raratu/Onsei-iOS-Models"
ENCODER_REVISION = "158b33fdb7fe95753922586c76bc8640feafd897"
ONNX_FILES = {
    "text_encoder": "text_encoder_int8.onnx",
    "speaker_encoder": "speaker_encoder.onnx",
    "duration": "duration.onnx",
    "context_kv": "context_kv.onnx",
    "dit_step": "dit_step_int8.onnx",
    "dacvae_decode": "dacvae_decode.onnx",
}

DEFAULT_STEPS = 4
# 公式サーバー (Irodori-TTS-Server) の既定に合わせ、80文字以上たまった句読点で区切って順に生成する
CHUNK_MIN_CHARS = 80
CHUNK_BOUNDARIES = frozenset("。、，,．.!！?？\n\r")
# 参照音声の前処理 (公式 SamplingRequest の既定値)
REF_NORMALIZE_DB = -16.0
PRESET_ID = re.compile(r"^[a-z][a-z0-9_-]{0,63}$")


def download() -> tuple[Path, Path]:
    from huggingface_hub import snapshot_download

    model = snapshot_download(
        MODEL_REPO,
        revision=MODEL_REVISION,
        allow_patterns=[
            *ONNX_FILES.values(),
            "config.json",
            "tokenizer/*",
            "README.md",
            "THIRD_PARTY_NOTICES.md",
            "LICENSES/*",
        ],
    )
    encoder = snapshot_download(
        ENCODER_REPO,
        revision=ENCODER_REVISION,
        allow_patterns=[
            "v4.1-small-mf/dacvae_encode.onnx",
            "README.md",
            "THIRD_PARTY_NOTICES.md",
            "LICENSES/*",
        ],
    )
    return Path(model), Path(encoder) / "v4.1-small-mf"


# ---- プリセット ----


def presets_path() -> Path:
    """プロジェクト側のプリセット。クラウドでは作業中のリポジトリにしか残らないため、git のルートに置く。"""
    configured = os.environ.get("GAME_VOICE_PRESETS")
    if configured:
        return Path(configured).resolve()
    try:
        top = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
        return Path(top) / "voice-presets.json"
    except (OSError, subprocess.CalledProcessError):
        return Path.cwd() / "voice-presets.json"


def validate_preset(preset: dict) -> dict:
    allowed = {"id", "name", "description", "caption", "voice", "seed", "speed", "num_steps"}
    if not isinstance(preset, dict) or set(preset) - allowed:
        raise ValueError(f"プリセットに使えるキーは {sorted(allowed)} です")
    if not PRESET_ID.fullmatch(str(preset.get("id", ""))):
        raise ValueError("id は小文字英字で始まる英数字・_・- の64文字以内にする")
    for key in ("name", "caption"):
        if not str(preset.get(key, "")).strip():
            raise ValueError(f"{key} は必須")
    result = {
        "id": preset["id"],
        "name": preset["name"].strip(),
        "description": str(preset.get("description", "")).strip(),
        "caption": preset["caption"].strip(),
        "voice": preset.get("voice") or "none",
        "seed": preset.get("seed"),
        "speed": float(preset.get("speed", 1.0)),
        "num_steps": preset.get("num_steps"),
    }
    check_settings(result)
    return result


def check_settings(settings: dict) -> None:
    seed, speed, steps = settings.get("seed"), settings.get("speed"), settings.get("num_steps")
    if seed is not None and not (isinstance(seed, int) and 0 <= seed < 2**32):
        raise ValueError("seed は 0〜2^32-1 の整数")
    if speed is not None and not 0.25 <= speed <= 4:
        raise ValueError("speed は 0.25〜4")
    if steps is not None and not (isinstance(steps, int) and 1 <= steps <= 100):
        raise ValueError("num_steps は 1〜100 の整数")
    seconds = settings.get("seconds")
    if seconds is not None and not 0.5 <= seconds <= 30:
        raise ValueError("seconds は 0.5〜30")


def read_presets(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    document = json.loads(path.read_text(encoding="utf-8"))
    presets = [validate_preset(p) for p in document["presets"]]
    # 参照音声のパスはプリセットファイルからの相対で書く (リポジトリごと移しても使えるように)
    for preset in presets:
        if preset["voice"] != "none":
            preset["voice"] = str((path.parent / preset["voice"]).resolve())
    return presets


def load_presets() -> dict[str, dict]:
    presets = {p["id"]: p for p in read_presets(BUILTIN_PRESETS)}
    presets.update((p["id"], p) for p in read_presets(presets_path()))
    return presets


def save_preset(preset: dict, overwrite: bool) -> Path:
    preset = validate_preset(preset)
    path = presets_path()
    if preset["id"] in load_presets() and not overwrite:
        raise ValueError(f"プリセットは既にある: {preset['id']} (更新は --overwrite)")
    if preset["voice"] != "none":
        voice = Path(preset["voice"]).resolve()
        if not voice.is_file():
            raise ValueError(f"参照音声が無い: {voice}")
        preset["voice"] = os.path.relpath(voice, path.parent).replace(os.sep, "/")
    document = (
        json.loads(path.read_text(encoding="utf-8"))
        if path.is_file()
        else {"version": 1, "presets": []}
    )
    document["presets"] = [p for p in document["presets"] if p["id"] != preset["id"]] + [preset]
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, suffix=".tmp", delete=False
    ) as temp:
        json.dump(document, temp, ensure_ascii=False, indent=2)
        temp.write("\n")
    os.replace(temp.name, path)
    return path


def resolve(values: dict, presets: dict[str, dict]) -> tuple[dict, dict | None]:
    """明示した値をプリセットより優先し、caption だけはプリセットの特徴に追記する (game-voice と同じ)。"""
    preset = None
    settings = {"caption": "", "voice": "none", "seed": None, "speed": 1.0, "num_steps": None}
    if values.get("preset"):
        try:
            preset = presets[values["preset"]]
        except KeyError:
            raise ValueError(f"プリセットが無い: {values['preset']}") from None
        settings.update({k: preset[k] for k in settings})
    for key in ("voice", "seed", "speed", "num_steps", "seconds"):
        if values.get(key) is not None:
            settings[key] = values[key]
    settings["caption"] = "\n".join(
        part for part in (settings["caption"], (values.get("caption") or "").strip()) if part
    )
    if values.get("voice") not in (None, "none"):
        settings["voice"] = str(Path(values["voice"]).resolve())
    check_settings(settings)
    return settings, preset


# ---- 推論 ----


def split_text(text: str) -> list[str]:
    chunks, current, count = [], [], 0
    for char in text:
        current.append(char)
        if not char.isspace():
            count += 1
        if char in CHUNK_BOUNDARIES and count >= CHUNK_MIN_CHARS:
            chunk = "".join(current).strip()
            if chunk:
                chunks.append(chunk)
            current, count = [], 0
    tail = "".join(current).strip()
    if tail:
        chunks.append(tail)
    return chunks or [text]


def flattening_point(latent, window: int = 20, std_max: float = 0.05, mean_max: float = 0.1) -> int:
    """末尾の無音区間の開始位置 (公式 find_flattening_point と同じ判定)。latent は (T, D)。"""
    import numpy as np

    padded = np.concatenate([latent, np.zeros((window, latent.shape[1]), latent.dtype)])
    for i in range(padded.shape[0] - window):
        part = padded[i : i + window]
        if part.std() < std_max and abs(part.mean()) < mean_max:
            return i
    return latent.shape[0]


class Synthesizer:
    def __init__(self) -> None:
        import onnxruntime as ort
        import torch
        from irodori_tts.text_normalization import normalize_text
        from irodori_tts.token_split import RareTokenSplitter
        from irodori_tts.watermark import SilentCipherWatermarker
        from tokenizers import Tokenizer

        model_dir, encoder_dir = download()
        config = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
        self.model_config = config["model"]
        self.inference_config = config["inference"]
        self.sample_rate = int(config["export"]["sample_rate"])
        self.hop_length = int(config["export"]["hop_length"])
        self.encoder_path = encoder_dir / "dacvae_encode.onnx"
        self.normalize_text = normalize_text

        options = ort.SessionOptions()
        options.intra_op_num_threads = torch.get_num_threads()
        options.inter_op_num_threads = 1
        # 逐次実行する複数グラフの待機スレッドが CPU を取り合わないようにする
        options.add_session_config_entry("session.intra_op.allow_spinning", "0")
        self.ort_options = options
        self.sessions = {name: self.session(model_dir / f) for name, f in ONNX_FILES.items()}
        self.reference_encoder = None

        tokenizer_dir = model_dir / "tokenizer"
        self.tokenizer = Tokenizer.from_file(str(tokenizer_dir / "tokenizer.json"))
        self.tokenizer.no_padding()
        self.tokenizer.no_truncation()
        special = json.loads((tokenizer_dir / "tokenizer_config.json").read_text(encoding="utf-8"))

        def token_id(name: str) -> int | None:
            token = special.get(name)
            token = token.get("content") if isinstance(token, dict) else token
            return None if token is None else self.tokenizer.token_to_id(token)

        self.bos_id = token_id("bos_token")
        if self.bos_id is None:
            raise RuntimeError("tokenizer に bos_token が無い")
        # 本文だけ、学習データで稀な長いトークンを分割して読み間違いを減らす (公式の推論と同じ)
        self.splitter = RareTokenSplitter(self.tokenizer)
        self.watermarker = SilentCipherWatermarker(device="cpu")
        if not self.watermarker.ready:
            raise RuntimeError("SilentCipher の透かしモデルを読み込めない (モデルの利用条件上、透かし無しでは出力しない)")

    def session(self, path: Path):
        import onnxruntime as ort

        return ort.InferenceSession(str(path), self.ort_options, providers=["CPUExecutionProvider"])

    def encode(self, text: str, max_length: int, *, split: bool):
        import numpy as np

        ids = self.splitter.encode(text) if split else self.tokenizer.encode(text, add_special_tokens=False).ids
        ids = [self.bos_id, *ids[: max_length - 1]]
        return np.array([ids], np.int64), np.ones((1, len(ids)), np.float32)

    def reference(self, path: str | None):
        import numpy as np

        latent_dim = int(self.model_config["latent_dim"])
        if path is None:
            length = int(self.model_config["speaker_patch_size"])
            return np.zeros((1, length, latent_dim), np.float32), np.zeros((1, length), np.float32)
        max_seconds = float(self.inference_config["ref_max_seconds"])
        digest = hashlib.sha256(Path(path).read_bytes())
        digest.update(
            json.dumps(
                {"encoder": ENCODER_REVISION, "normalize_db": REF_NORMALIZE_DB, "max_seconds": max_seconds, "average": 8},
                sort_keys=True,
            ).encode()
        )
        cache = CACHE_DIR / (digest.hexdigest() + ".npy")
        if cache.is_file():
            latent = np.load(cache, allow_pickle=False)
        else:
            latent = self.encode_reference(path, max_seconds)
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            np.save(cache, latent, allow_pickle=False)
        if max_seconds > 0:
            latent = latent[:, : max(1, math.ceil(max_seconds * self.sample_rate / self.hop_length))]
        return latent, np.ones(latent.shape[:2], np.float32)

    def encode_reference(self, path: str, max_seconds: float):
        import numpy as np
        import pyloudnorm
        import soundfile as sf
        import torch
        import torchaudio

        data, sample_rate = sf.read(path, dtype="float32", always_2d=True)
        waveform = torch.from_numpy(data.mean(axis=1))[None]
        if max_seconds > 0:
            waveform = waveform[:, : max(1, int(max_seconds * sample_rate))]
        if sample_rate != self.sample_rate:
            waveform = torchaudio.functional.resample(waveform, sample_rate, self.sample_rate)
        # 公式は audiotools で -16 LUFS に揃え、1 を超えたらピークで割る。同じ BS.1770 の測定を pyloudnorm で行う
        loudness = pyloudnorm.Meter(self.sample_rate).integrated_loudness(waveform[0].numpy())
        if not math.isfinite(loudness):
            raise ValueError(f"参照音声が無音: {path}")
        waveform = waveform * 10 ** ((REF_NORMALIZE_DB - loudness) / 20)
        peak = float(waveform.abs().max())
        if peak > 1:
            waveform = waveform / peak
        if self.reference_encoder is None:
            self.reference_encoder = self.session(self.encoder_path)
        feed = {"waveform": waveform.unsqueeze(0).contiguous().numpy()}
        # 配布 ONNX は事後分布からサンプリングするため、8回の平均を固定して再利用する
        latent = sum(self.reference_encoder.run(None, feed)[0] for _ in range(8)) / 8
        return np.ascontiguousarray(latent, dtype=np.float32)

    def synthesize_chunk(self, text: str, caption: str, ref, seed: int, steps: int, speed: float, seconds: float | None):
        import numpy as np
        import torch

        text = self.normalize_text(text).strip()
        if not text:
            raise ValueError("正規化後の本文が空")
        ids, text_mask = self.encode(text, self.inference_config["max_text_len"], split=True)
        text_state = self.sessions["text_encoder"].run(["text_state"], {"input_ids": ids, "mask": text_mask})[0]
        ids, caption_mask = self.encode(caption, self.inference_config["max_caption_len"], split=False)
        if not caption:
            caption_mask.fill(0)
        caption_state = self.sessions["text_encoder"].run(
            ["caption_state"], {"input_ids": ids, "mask": caption_mask}
        )[0]
        ref_latent, ref_mask = ref
        speaker_state, speaker_mask = self.sessions["speaker_encoder"].run(
            None, {"ref_latent": ref_latent, "mask": ref_mask}
        )
        min_steps = math.ceil(0.5 * self.sample_rate / self.hop_length)
        max_steps = math.floor(30 * self.sample_rate / self.hop_length)
        if seconds is not None:
            target = max(1, int(min(30, max(0.5, seconds / speed)) * self.sample_rate))
            latent_steps = math.ceil(target / self.hop_length)
        else:
            log_frames = float(
                self.sessions["duration"].run(
                    None,
                    {
                        "text_state": text_state,
                        "text_mask": text_mask,
                        "speaker_state": speaker_state,
                        "has_speaker": np.array([ref_mask.any()], np.float32),
                        "caption_state": caption_state,
                        "caption_mask": caption_mask,
                        "has_caption": np.array([bool(caption)], np.float32),
                    },
                )[0][0]
            )
            latent_steps = max(min_steps, min(max_steps, round(math.expm1(log_frames) / speed)))
            target = latent_steps * self.hop_length
        context = self.sessions["context_kv"]
        values = context.run(
            None, {"text_state": text_state, "speaker_state": speaker_state, "caption_state": caption_state}
        )
        feed = {output.name: value for output, value in zip(context.get_outputs(), values, strict=True)}
        feed.update(
            {
                "text_mask": text_mask,
                "speaker_mask": speaker_mask.astype(np.float32),
                "caption_mask": caption_mask,
                "speaker_kv_scales": np.ones(self.model_config["num_layers"], np.float32),
            }
        )
        # 同じ seed で同じ初期ノイズになるよう、公式と同じく torch の乱数を使う
        generator = torch.Generator(device="cpu").manual_seed(seed)
        x = torch.randn((1, latent_steps, self.model_config["latent_dim"]), generator=generator).numpy()
        schedule = torch.linspace(1, 0, steps + 1, dtype=torch.float32).numpy()
        for current, following in zip(schedule[:-1], schedule[1:], strict=True):
            velocity = self.sessions["dit_step"].run(
                None,
                {
                    **feed,
                    "x_t": x,
                    "t": np.array([current], np.float32),
                    "delta_t": np.array([current - following], np.float32),
                },
            )[0]
            x = x + velocity * (following - current)
        waveform = self.sessions["dacvae_decode"].run(None, {"latent": x})[0][0]
        point = flattening_point(x[0])
        if point > 0:
            target = min(target, point * self.hop_length)
        audio = torch.from_numpy(np.ascontiguousarray(waveform[:, :target]))
        return self.watermarker.encode_one(audio, sample_rate=self.sample_rate)

    def generate(self, text: str, settings: dict) -> tuple:
        import torch

        seed = settings["seed"] if settings["seed"] is not None else secrets.randbelow(2**32)
        steps = settings["num_steps"] or DEFAULT_STEPS
        voice = None if settings["voice"] == "none" else settings["voice"]
        if voice is not None and not Path(voice).is_file():
            raise ValueError(f"参照音声が無い: {voice}")
        ref = self.reference(voice)
        seconds = settings.get("seconds")
        chunks = [text] if seconds is not None else split_text(text)
        audio = torch.cat(
            [
                self.synthesize_chunk(c, settings["caption"], ref, seed, steps, settings["speed"], seconds).reshape(1, -1)
                for c in chunks
            ],
            dim=-1,
        )
        return audio, seed, steps


def write_output(path: Path, audio, sample_rate: int, metadata: dict, force: bool) -> dict:
    import soundfile as sf

    if path.suffix.lower() != ".wav":
        raise ValueError(f"出力は .wav にする: {path}")
    meta_path = path.with_suffix(".json")
    if not force and (path.exists() or meta_path.exists()):
        raise FileExistsError(f"出力先が既にある (上書きは --force): {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    samples = audio.clamp(-1, 1).reshape(-1).numpy()
    sf.write(path, samples, sample_rate, subtype="PCM_16")
    metadata = {**metadata, "duration_seconds": round(len(samples) / sample_rate, 3), "sample_rate": sample_rate}
    meta_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return {"audio": str(path), "metadata": str(meta_path), **metadata}


def run_items(items: list[dict], common: dict, force: bool) -> int:
    """一括生成。common の seed は項目ごとに連番を足す (game-voice と同じ)。失敗した項目があれば 1 を返す。"""
    presets = load_presets()
    outputs = [str(Path(item["output"]).resolve()).casefold() for item in items]
    if len(set(outputs)) != len(outputs):
        raise ValueError("output が重複している")
    synth = Synthesizer()
    failed = 0
    for index, item in enumerate(items):
        try:
            values = {**common, **{k: v for k, v in item.items() if v is not None}}
            values["caption"] = item.get("caption") or common.get("caption")
            if item.get("seed") is None:
                values["seed"] = None if common.get("seed") is None else (common["seed"] + index) % 2**32
            settings, preset = resolve(values, presets)
            if item.get("seed") is None and common.get("seed") is None and settings["seed"] is not None:
                settings["seed"] = (settings["seed"] + index) % 2**32
            started = time.perf_counter()
            audio, seed, steps = synth.generate(item["text"], settings)
            metadata = {
                "model": MODEL_REPO,
                "model_revision": MODEL_REVISION,
                "inference_engine": "onnx-int8",
                "text": item["text"],
                "preset": preset["id"] if preset else None,
                "caption": settings["caption"],
                "voice": settings["voice"],
                "seed": seed,
                "speed": settings["speed"],
                "seconds_requested": settings.get("seconds"),
                "num_steps": steps,
                "generation_seconds": round(time.perf_counter() - started, 3),
                "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            }
            result = write_output(Path(item["output"]), audio, synth.sample_rate, metadata, force)
            print(json.dumps(result, ensure_ascii=False))
        except Exception as exc:  # 一括生成は失敗した項目を報告して続ける
            failed += 1
            print(json.dumps({"output": item.get("output"), "error": str(exc)}, ensure_ascii=False))
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="game-voice", description="日本語の台詞を WAV (48kHz・16bit) で生成する")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_settings(p: argparse.ArgumentParser) -> None:
        p.add_argument("--preset", help="キャラクタープリセットの ID")
        p.add_argument("--caption", help="声質・感情・話し方の説明 (プリセットの説明に追記される)")
        p.add_argument("--voice", help="参照音声のファイル (WAV/FLAC/OGG/MP3)。none で参照なし")
        p.add_argument("--seed", type=int)
        p.add_argument("--speed", type=float, help="0.25〜4 (既定 1)")
        p.add_argument("--seconds", type=float, help="長さを固定する (0.5〜30 秒)。省略時は自動")
        p.add_argument("--steps", type=int, dest="num_steps", help="1〜100 (既定 4)")
        p.add_argument("--force", action="store_true", help="既存の出力を上書きする")

    say = sub.add_parser("say", help="1つの台詞を生成する")
    say.add_argument("text")
    say.add_argument("-o", "--output", required=True, help="出力する .wav (同名の .json に設定を記録)")
    add_settings(say)

    batch = sub.add_parser("batch", help="JSON に書いた複数の台詞を、モデルを1回読み込んで生成する")
    batch.add_argument("file", help='{"preset": ..., "items": [{"text": ..., "output": ..., "preset": ...}]}')
    batch.add_argument("--force", action="store_true")

    presets = sub.add_parser("presets", help="プリセットの一覧、または ID を指定して詳細を表示する")
    presets.add_argument("id", nargs="?")

    save = sub.add_parser("save-preset", help="プリセットを git のルートの voice-presets.json に保存する")
    save.add_argument("json", help='{"id", "name", "caption", "description", "voice", "seed", "speed", "num_steps"}')
    save.add_argument("--overwrite", action="store_true")

    sub.add_parser("download", help="モデルを取得する (cloud-prepare が実行する)")

    args = parser.parse_args()
    try:
        if args.command == "say":
            keys = ("preset", "caption", "voice", "seed", "speed", "seconds", "num_steps")
            item = {"text": args.text, "output": args.output, **{k: getattr(args, k) for k in keys}}
            return run_items([item], {}, args.force)
        if args.command == "batch":
            document = json.loads(Path(args.file).read_text(encoding="utf-8"))
            items = document.pop("items")
            return run_items(items, document, args.force)
        if args.command == "presets":
            catalog = load_presets()
            if args.id:
                if args.id not in catalog:
                    raise ValueError(f"プリセットが無い: {args.id}")
                print(json.dumps(catalog[args.id], ensure_ascii=False, indent=2))
            else:
                for p in catalog.values():
                    print(f"{p['id']}: {p['name']} - {p['description']}")
                print(f"(プロジェクトのプリセット: {presets_path()})")
            return 0
        if args.command == "save-preset":
            print(f"保存した: {save_preset(json.loads(args.json), args.overwrite)}")
            return 0
        if args.command == "download":
            download()
            from irodori_tts.watermark import SilentCipherWatermarker

            if not SilentCipherWatermarker(device="cpu").ready:
                raise RuntimeError("SilentCipher の透かしモデルを取得できない")
            return 0
    except (ValueError, KeyError, FileExistsError, OSError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"エラー: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
