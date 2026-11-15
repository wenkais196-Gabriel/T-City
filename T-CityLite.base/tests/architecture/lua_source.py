"""Lua 源码的轻量词法工具 —— 架构闸门共用的唯一实现。

四件事：跳过注释、找出字符串字面量区间、按括号配平找调用范围、把注释/字符串抹成空白
（`blank_noise`，长度与行号不变，便于在"结构化视图"上跑正则）。
刻意保持线性扫描（不用带嵌套量词的正则），既有性能也有可预测性。

为什么不各写一份：每个新闸门都抄一遍「剥注释/字符串」的扫描器时，SonarCloud 会把它们
算成新代码重复（S6 报过 7.1%，阶段 D 报过 15.8%）。
"""

from __future__ import annotations

import re
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


def argument_spans(source: str, open_index: int, close_index: int | None = None) -> list[tuple[int, int]]:
    """按顶层逗号切参数，返回每个参数的 `(start, end)` 偏移。

    `source` 应是 `blank_noise(...)` 之后的结构化视图：注释已抹白、字符串可保留，
    所以括号/逗号只可能来自真代码。三个闸门共用这一份切分（各抄一遍会被 Sonar 判重复）。
    """
    if close_index is None:
        close_index = match_paren(source, open_index)
    bounds: list[tuple[int, int]] = []
    start, depth = open_index + 1, 0
    for index in range(open_index + 1, max(close_index - 1, open_index + 1)):
        char = source[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            bounds.append((start, index))
            start = index + 1
    bounds.append((start, close_index - 1))
    return bounds


def line_of(source: str, index: int) -> int:
    return source.count("\n", 0, index) + 1


def blank(text: str) -> str:
    """用空格替换，保留换行（长度/行号不变）。"""
    return "".join("\n" if char == "\n" else " " for char in text)


_LONG_BRACKET = re.compile(r"\[(=*)\[")


def blank_noise(source: str, *, keep_strings: bool = False) -> str:
    """把注释（可选：字符串字面量）替换成空格，长度与行号保持不变。

    `keep_strings=False` → 结构化视图（只剩代码骨架，正则不会误匹配文案里的示例）；
    `keep_strings=True`  → 保留字符串原文，用于"字符串里出现这段文本"的判定。
    """
    out: list[str] = []
    index, size = 0, len(source)
    while index < size:
        char = source[index]
        if char == "-" and source.startswith("--", index):
            long_match = _LONG_BRACKET.match(source, index + 2)
            if long_match:
                close = "]" + long_match.group(1) + "]"
                end = source.find(close, long_match.end())
                end = size if end == -1 else end + len(close)
            else:
                end = source.find("\n", index)
                end = size if end == -1 else end
            out.append(blank(source[index:end]))
            index = end
            continue
        if char == "[":
            long_match = _LONG_BRACKET.match(source, index)
            if long_match:
                close = "]" + long_match.group(1) + "]"
                end = source.find(close, long_match.end())
                end = size if end == -1 else end + len(close)
                chunk = source[index:end]
                out.append(chunk if keep_strings else blank(chunk))
                index = end
                continue
        if char in "\"'":
            end = _skip_quoted(source, index, char)
            chunk = source[index:end]
            out.append(chunk if keep_strings else blank(chunk))
            index = end
            continue
        out.append(char)
        index += 1
    return "".join(out)
