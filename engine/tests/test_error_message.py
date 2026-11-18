"""_error records an error that has no strerror (anything but an OSError) with its class and message, and does not
raise. It is what a per-file error isolation reports through."""
from semsearch import indexer


def test_error_without_strerror_is_counted_by_class_and_does_not_raise():
    ctx = {"errors": {}, "folder_no": {}}
    indexer._error(ctx, ValueError("bad value"), -1)
    indexer._error(ctx, ValueError("again"), -1)
    assert ctx["errors"] == {"ValueError": 2}


def test_error_message_uses_strerror_when_there_is_one(monkeypatch):
    seen = []
    monkeypatch.setattr(indexer.events, "write", lambda *a, **k: seen.append((a, k)))
    indexer._error({"errors": {}, "folder_no": {}}, OSError(13, "Permission denied"), 0)
    (args, kw) = seen[0]
    assert kw["message"] == "Permission denied" and kw["class"] == "PermissionError"
