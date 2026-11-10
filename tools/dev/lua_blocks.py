"""Lua 源码的**轻量**结构解析：词法切分 + 块配对（tools/dev 内部用）。

为什么要自己写：预算探针（P2-4）要判断"这条循环多久转一圈"，而用正则去截循环体会一直错 ——
字符串里的 `end`、`elseif … then`、嵌套 `CreateThread` 都会让截断提前或延后。十几轮复核里
每一轮都在抓这个。切词之后按 token 配对就能一次解决：

  * 字符串/长字符串/注释都切成单个 token → `print("end")` 不会被当成块结束；
  * 开块只认 `do` / `function` / `if` / `repeat`，收块只认 `end` / `until`
    （`then` 不单独计数：`if … then` 的 `if` 已经算过一次，`elseif … then` 不能再算）；
  * 于是 `for … do` 与 `while … do` 都是 `do` 开块，配一次 `end`。

不是完整的 Lua 解析器：不建 AST，只回答"这个循环的体从哪里到哪里"。
"""

from __future__ import annotations

import re

LONG_BRACKET = re.compile(r"\[(=*)\[")
NUMBER = re.compile(r"0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
SYMBOL = re.compile(r"==|~=|<=|>=|\.\.\.|\.\.|::|[^\s]")

OPENERS = {"do", "function", "if", "repeat"}
CLOSERS = {"end", "until"}


def tokenize(code: str) -> list[tuple[str, str, int]]:
    """切成 (kind, value, offset)。kind ∈ {name, number, string, symbol}。"""
    tokens: list[tuple[str, str, int]] = []
    index = 0
    length = len(code)
    while index < length:
        char = code[index]
        if char in " \t\r\n":
            index += 1
            continue
        if code.startswith("--", index):                      # 行注释（块注释已在 strip_comments 去掉）
            newline = code.find("\n", index)
            index = length if newline == -1 else newline
            continue
        long_match = LONG_BRACKET.match(code, index)
        if long_match:                                        # [[ ... ]] / [==[ ... ]==]
            closer = "]" + long_match.group(1) + "]"
            end = code.find(closer, long_match.end())
            end = length if end == -1 else end + len(closer)
            tokens.append(("string", code[index:end], index))
            index = end
            continue
        if char in "'\"":                                     # 引号字符串，处理转义
            quote = char
            cursor = index + 1
            while cursor < length:
                if code[cursor] == "\\":
                    cursor += 2
                    continue
                if code[cursor] == quote:
                    cursor += 1
                    break
                cursor += 1
            tokens.append(("string", code[index:cursor], index))
            index = cursor
            continue
        number_match = NUMBER.match(code, index)
        if number_match:
            tokens.append(("number", number_match.group(0), index))
            index = number_match.end()
            continue
        name_match = NAME.match(code, index)
        if name_match:
            tokens.append(("name", name_match.group(0), index))
            index = name_match.end()
            continue
        symbol_match = SYMBOL.match(code, index)
        tokens.append(("symbol", symbol_match.group(0), index))
        index = symbol_match.end()
    return tokens


def depths(tokens: list[tuple[str, str, int]]) -> list[int]:
    """每个 token **所属**的块深度（收块 token 记在它关闭的那一层）。"""
    result: list[int] = []
    depth = 0
    for kind, value, _offset in tokens:
        if kind == "name" and value in CLOSERS:
            depth -= 1
            result.append(depth)
            continue
        result.append(depth)
        if kind == "name" and value in OPENERS:
            depth += 1
    return result


def loops(tokens: list[tuple[str, str, int]]) -> list[dict]:
    """找出所有循环：`while … do`、`for … do`、`repeat … until`。

    返回 [{kind, start, body_start, body_end, condition}]，索引都是 token 下标。
    """
    found: list[dict] = []
    level = depths(tokens)
    for index, (kind, value, _offset) in enumerate(tokens):
        if kind != "name":
            continue
        lowered = value.lower()
        if lowered == "repeat":
            depth = level[index]
            for cursor in range(index + 1, len(tokens)):
                if tokens[cursor][1].lower() == "until" and level[cursor] == depth:
                    # 条件要从 `until` 之后取到块外：`repeat … until false` 才是无限循环，
                    # 条件不取就会把所有 repeat 都当无限（早先就是这么错的）。
                    condition: list[str] = []
                    for later in range(cursor + 1, len(tokens)):
                        if level[later] < depth:
                            break
                        condition.append(tokens[later][1])
                        if len(condition) >= 12:
                            break
                    found.append({"kind": "repeat", "start": index, "body_start": index + 1,
                                  "body_end": cursor, "condition": " ".join(condition)})
                    break
            continue
        if lowered not in {"while", "for"}:
            continue
        depth = level[index]
        do_index = None
        for cursor in range(index + 1, len(tokens)):
            token_kind, token_value, _ = tokens[cursor]
            if token_kind == "name" and token_value.lower() == "do" and level[cursor] == depth:
                do_index = cursor
                break
        if do_index is None:
            continue
        end_index = None
        for cursor in range(do_index + 1, len(tokens)):
            if tokens[cursor][1].lower() == "end" and level[cursor] == depth:
                end_index = cursor
                break
        condition_tokens = [token[1] for token in tokens[index + 1:do_index]]
        found.append({
            "kind": lowered,
            "start": index,
            "body_start": do_index + 1,
            "body_end": end_index if end_index is not None else len(tokens),
            "condition": " ".join(condition_tokens),
        })
    return found
