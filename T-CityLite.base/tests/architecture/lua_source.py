"""Lua 源码的轻量词法工具 —— 两个扫描器（跨资源回调 / 金额格式化）共用。

只做三件事：跳过注释、找出字符串字面量区间、按括号配平找调用范围。
刻意保持线性扫描（不用带嵌套量词的正则），既有性能也有可预测性。
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Literal:
    start: int
    text: str          # 含引号的原文


def literals(source: str) -> list[Literal]:
    """返回所有字符串字面量（跳过 `--` 行注释）。"""
    found: list[Literal] = []
    index, size = 0, len(source)
    while index < size:
        char = source[index]
        if char == "-" and source.startswith("--", index):
            newline = source.find("\n", index)
            index = size if newline == -1 else newline
            continue
        if char in "'\"":
            end = _skip_quoted(source, index, char)
            found.append(Literal(index, source[index:end]))
            index = end
            continue
        if source.startswith("[[", index):
            close = source.find("]]", index)
            close = size if close == -1 else close + 2
            found.append(Literal(index, source[index:close]))
            index = close
            continue
        index += 1
    return found


def _skip_quoted(source: str, index: int, quote: str) -> int:
    cursor = index + 1
    size = len(source)
    while cursor < size:
        if source[cursor] == "\\":
            cursor += 2
            continue
        if source[cursor] == quote:
            return cursor + 1
        cursor += 1
    return size


def string_spans(source: str) -> list[tuple[int, int]]:
    return [(item.start, item.start + len(item.text)) for item in literals(source)]


def in_spans(index: int, spans: list[tuple[int, int]]) -> bool:
    for start, end in spans:
        if start <= index < end:
            return True
    return False


def match_paren(source: str, open_index: int) -> int:
    """从 `(` 起做括号配平，返回对应 `)` 之后的位置（遇到 EOF 返回 len）。"""
    depth = 0
    cursor, size = open_index, len(source)
    while cursor < size:
        char = source[cursor]
        if char in "'\"":
            cursor = _skip_quoted(source, cursor, char)
            continue
        if char in "({[":
            depth += 1
        elif char in ")}]":
            depth -= 1
            if depth == 0:
                return cursor + 1
        cursor += 1
    return size


def line_of(source: str, index: int) -> int:
    return source.count("\n", 0, index) + 1
