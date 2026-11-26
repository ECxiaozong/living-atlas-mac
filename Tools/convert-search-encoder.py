"""Rebuild the bundled Core ML encoder from the pinned upstream safetensors checkout.

Developer-only conversion, tested with torch 2.15.0, transformers 5.3.0 and coremltools 9.0.
Usage: python convert-search-encoder.py PATH_TO_BGE OUTPUT.mlpackage
"""
import argparse
import hashlib
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights,
)
from transformers import AutoModel


class PassageEncoder(torch.nn.Module):
    """Fixed-length BERT forward pass using Core ML traceable tensor operations."""

    def __init__(self, directory):
        super().__init__()
        self.bert = AutoModel.from_pretrained(directory, local_files_only=True).eval()

    def forward(self, tokens):
        embedding = self.bert.embeddings
        hidden = embedding.LayerNorm(
            embedding.word_embeddings(tokens)
            + embedding.position_embeddings.weight[:128]
            + embedding.token_type_embeddings.weight[0]
        )
        mask = (tokens == 0).to(hidden.dtype)[:, None, None, :] * -10000.0

        def heads(matrix):
            return matrix.reshape(1, 128, 8, 64).transpose(1, 2)

        for layer in self.bert.encoder.layer:
            attention = layer.attention.self
            query = heads(attention.query(hidden))
            key = heads(attention.key(hidden))
            value = heads(attention.value(hidden))
            weights = torch.softmax(query @ key.transpose(-1, -2) * 0.125 + mask, dim=-1)
            context = (weights @ value).transpose(1, 2).reshape(1, 128, 512)
            context = layer.attention.output.LayerNorm(hidden + layer.attention.output.dense(context))
            intermediate = torch.nn.functional.gelu(layer.intermediate.dense(context))
            hidden = layer.output.LayerNorm(context + layer.output.dense(intermediate))
        return hidden[:, 0, :]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    expected = "354763b9b1357bc9c44f62c6be2276321081ed2567773608c0d0785b61d5a026"
    if hashlib.sha256((args.checkout / "model.safetensors").read_bytes()).hexdigest() != expected:
        parser.error("The weights do not match revision 7999e1d3359715c523056ef9478215996d62a620.")
    encoder = PassageEncoder(args.checkout).eval()
    tokens = torch.tensor([[101, 1111, 102] + [0] * 125], dtype=torch.int32)
    with torch.inference_mode():
        reference = encoder.bert(input_ids=tokens, attention_mask=tokens != 0).last_hidden_state[:, 0, :]
        torch.testing.assert_close(encoder(tokens), reference, rtol=1e-4, atol=1e-4)
        traced = torch.jit.trace(encoder, tokens)
    model = ct.convert(
        traced, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
        inputs=[ct.TensorType(name="tokens", shape=(1, 128), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    )
    config = OpLinearQuantizerConfig(dtype="int8", mode="linear_symmetric", weight_threshold=512)
    model = linear_quantize_weights(model, config=OptimizationConfig(global_config=config))
    model.author = "Beijing Academy of Artificial Intelligence"
    model.license = "MIT"
    model.short_description = "BAAI/bge-small-zh-v1.5, 128 tokens, CLS output"
    model.save(str(args.output))


if __name__ == "__main__":
    main()
