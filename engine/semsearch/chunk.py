def chunk_spans(text, count, max_tokens=400, overlap=60):
    """Split text into (start, end) char spans of ~max_tokens, breaking at line
    boundaries and overlapping by ~overlap tokens. `count` returns a token count."""
    units = []  # (start, end, tokens)
    pos = 0
    for line in text.splitlines(keepends=True):
        s, e = pos, pos + len(line)
        pos = e
        if count(line) > max_tokens:
            # shortcut: over-long lines are cut by characters (2 chars/token, conservative for the 512-token e5 limit), not by tokens
            step = max_tokens * 2
            for a in range(s, e, step):
                b = min(a + step, e)
                units.append((a, b, max_tokens))
        else:
            units.append((s, e, count(line)))

    spans = []
    i, n = 0, len(units)
    while i < n:
        j, tot = i, 0
        while j < n and (j == i or tot + units[j][2] <= max_tokens):
            tot += units[j][2]
            j += 1
        spans.append((units[i][0], units[j - 1][1]))
        if j >= n:
            break
        k, ov = j, 0
        while k - 1 > i and ov + units[k - 1][2] <= overlap:
            k -= 1
            ov += units[k][2]
        i = k if k > i else j
    return spans
