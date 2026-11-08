#!/usr/bin/env python3
"""Read-only interoperable Veyra sync-envelope verifier.

This is format tooling, not a desktop GitHub sync client. It never reads credentials,
contacts a server, writes user memory, or prints decrypted content. Dates inside the
Swift JSON document use seconds since 2001-01-01T00:00:00Z (Foundation's default).
"""
from __future__ import annotations

import hashlib
import json
import uuid

HEADER = b"VEYRA-SYNC\x00\x00\x00\x01"
ITERATIONS = 600_000
MAXIMUM_DOCUMENT_BYTES = 8 * 1024 * 1024


def validate_document(value: object, repository_id: int | None = None) -> dict:
    """Check the outer interchange contract; app import performs full typed validation."""
    if not isinstance(value, dict) or set(value) != {
        "version", "repositoryID", "notes", "chats", "knowledge", "tombstones", "includesPrivateWorkspaces", "chatOrder"
    }:
        raise ValueError("Unsupported sync document")
    if type(value["version"]) is not int or value["version"] != 1:
        raise ValueError("Unsupported sync document version")
    if type(value["repositoryID"]) is not int or value["repositoryID"] <= 0:
        raise ValueError("Invalid repository binding")
    if repository_id is not None and value["repositoryID"] != repository_id:
        raise ValueError("Repository identity changed")
    if type(value["includesPrivateWorkspaces"]) is not bool:
        raise ValueError("Invalid private workspace scope")
    for key in ("notes", "chats", "knowledge", "tombstones"):
        if not isinstance(value[key], list):
            raise ValueError("Invalid record collection")
    if len(value["tombstones"]) > 20_000:
        raise ValueError("Too many deletion markers")
    seen = set()
    for marker in value["tombstones"]:
        if not isinstance(marker, str) or marker in seen:
            raise ValueError("Invalid deletion marker")
        kind, separator, identifier = marker.partition(":")
        if kind not in ("note", "chat") or separator != ":":
            raise ValueError("Invalid deletion marker")
        try:
            if str(uuid.UUID(identifier)) != identifier:
                raise ValueError("Noncanonical deletion identity")
        except (ValueError, AttributeError) as exc:
            raise ValueError("Invalid deletion identity") from exc
        seen.add(marker)
    return value


def decrypt(encrypted: bytes, passphrase: str, repository_id: int | None = None) -> dict:
    if not isinstance(encrypted, bytes) or not 58 <= len(encrypted) <= MAXIMUM_DOCUMENT_BYTES + 58:
        raise ValueError("Invalid encrypted sync size")
    if not encrypted.startswith(HEADER):
        raise ValueError("Unsupported encrypted sync format")
    if not isinstance(passphrase, str) or not passphrase or len(passphrase.encode("utf-8")) > 4096:
        raise ValueError("Invalid passphrase")
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.exceptions import InvalidTag

    key = hashlib.pbkdf2_hmac("sha256", passphrase.encode("utf-8"), encrypted[14:30], ITERATIONS, 32)
    try:
        raw = AESGCM(key).decrypt(encrypted[30:42], encrypted[42:], encrypted[:42])
        value = json.loads(raw)
    except (InvalidTag, ValueError, UnicodeError) as exc:
        raise ValueError("Incorrect passphrase or damaged encrypted sync file") from exc
    return validate_document(value, repository_id=repository_id)
