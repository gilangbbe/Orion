"""Model loading + generation with the Task 3 performance metrics.

Metrics captured (study Task 3 "Also measure"):
  load_seconds, weights_gb (post-load MLX resident), ttft_seconds, tokens_per_sec,
  total_seconds, peak_memory_gb (MLX peak during generation), prompt_tokens, gen_tokens.
"""
from __future__ import annotations

import gc
import time
from dataclasses import dataclass, asdict
from typing import Any

import mlx.core as mx
from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler


@dataclass
class GenResult:
    text: str
    ttft_seconds: float
    total_seconds: float
    prompt_tokens: int
    gen_tokens: int
    prompt_tps: float
    gen_tps: float
    peak_memory_gb: float        # process-wide MLX peak: weights + KV + activations
    kv_activation_peak_gb: float  # mlx_lm's own per-generation figure (already GB)
    finish_reason: str


class ModelRunner:
    def __init__(self, hf_repo: str, temperature: float = 0.0, top_p: float = 1.0,
                 max_gen_tokens: int = 900, seed: int = 0):
        self.hf_repo = hf_repo
        self.temperature = temperature
        self.top_p = top_p
        self.max_gen_tokens = max_gen_tokens
        self.seed = seed
        self.model = None
        self.tokenizer = None
        self.load_seconds = 0.0
        self.weights_gb = 0.0

    def load(self) -> None:
        mx.reset_peak_memory()
        before = mx.get_active_memory()
        t0 = time.perf_counter()
        self.model, self.tokenizer = load(self.hf_repo)
        # force materialisation of lazily-loaded params
        mx.eval(self.model.parameters())
        self.load_seconds = time.perf_counter() - t0
        self.weights_gb = (mx.get_active_memory() - before) / 1e9
        # Keep the peak counter running from here so generate() reports a PROCESS-WIDE
        # peak (weights + KV + activations), not just the per-call delta.

    def generate(self, messages: list[dict], max_gen_tokens: int | None = None) -> GenResult:
        assert self.model is not None and self.tokenizer is not None, "call load() first"
        mx.random.seed(self.seed)
        # Baseline = no extended "thinking". Qwen3 / hybrid models add <think> blocks unless
        # told otherwise; keep the comparison about the answer, not the scratchpad.
        try:
            prompt = self.tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False, enable_thinking=False
            )
        except TypeError:
            prompt = self.tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False
            )
        max_toks = max_gen_tokens or self.max_gen_tokens
        sampler = make_sampler(temp=self.temperature, top_p=self.top_p)

        parts: list[str] = []
        t0 = time.perf_counter()
        ttft = 0.0
        last: Any = None
        for i, resp in enumerate(stream_generate(
            self.model, self.tokenizer, prompt, max_tokens=max_toks, sampler=sampler
        )):
            if i == 0:
                ttft = time.perf_counter() - t0
            parts.append(resp.text)
            last = resp
        total = time.perf_counter() - t0

        proc_peak_gb = round(mx.get_peak_memory() / 1e9, 3)
        if last is None:  # produced nothing
            return GenResult("", ttft, total, 0, 0, 0.0, 0.0, proc_peak_gb, 0.0, "empty")
        return GenResult(
            text="".join(parts),
            ttft_seconds=round(ttft, 4),
            total_seconds=round(total, 4),
            prompt_tokens=int(getattr(last, "prompt_tokens", 0)),
            gen_tokens=int(getattr(last, "generation_tokens", 0)),
            prompt_tps=round(float(getattr(last, "prompt_tps", 0.0)), 2),
            gen_tps=round(float(getattr(last, "generation_tps", 0.0)), 2),
            peak_memory_gb=proc_peak_gb,
            kv_activation_peak_gb=round(float(getattr(last, "peak_memory", 0.0)), 3),
            finish_reason=str(getattr(last, "finish_reason", "") or "length"),
        )

    def unload(self) -> None:
        self.model = None
        self.tokenizer = None
        gc.collect()
        try:
            mx.clear_cache()
        except Exception:
            pass


def gen_result_dict(g: GenResult) -> dict:
    return asdict(g)
