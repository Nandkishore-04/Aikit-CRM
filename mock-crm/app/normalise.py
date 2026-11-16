"""Phone / email normalisation used for lead deduplication.

DEDUP depends on these functions: two enquiries are "the same customer" when their
normalised phone or normalised email match within a tenant.
"""
import re


def normalise_phone(raw: str | None) -> str | None:
    """Return a UAE number as digits with country code, e.g. '971501234567'.

    Handles: '050 123 4567', '+971 50 123 4567', '00971501234567', '501234567'.
    Non-UAE numbers are returned as plain digits. Empty input -> None.
    """
    if not raw:
        return None
    digits = re.sub(r"\D", "", raw)        # keep digits only
    if not digits:
        return None
    if digits.startswith("00"):            # international prefix 00971... -> 971...
        digits = digits[2:]
    if digits.startswith("971"):           # already has country code
        return digits
    if digits.startswith("0") and len(digits) == 10:   # local 05X XXX XXXX
        return "971" + digits[1:]
    if digits.startswith("5") and len(digits) == 9:    # mobile without leading 0
        return "971" + digits
    return digits


def normalise_email(raw: str | None) -> str | None:
    """Trim + lowercase. Empty input -> None (so the UNIQUE index ignores it)."""
    if not raw:
        return None
    email = raw.strip().lower()
    return email or None
