# phone/email cleanup used for dedup.
# two enquiries are the same customer if the cleaned phone or email match (same tenant)
import re


def normalise_phone(raw: str | None) -> str | None:
    # UAE numbers -> 9715XXXXXXXX
    # e.g. '050 123 4567', '+971 50 123 4567', '00971501234567', '501234567'
    # anything else just becomes digits, empty -> None
    if not raw:
        return None
    digits = re.sub(r"\D", "", raw)        # keep digits only
    if not digits:
        return None
    if digits.startswith("00"):            # 00971.. -> 971..
        digits = digits[2:]
    if digits.startswith("971"):           # already has 971
        return digits
    if digits.startswith("0") and len(digits) == 10:   # 05X XXX XXXX
        return "971" + digits[1:]
    if digits.startswith("5") and len(digits) == 9:    # 5X XXX XXXX, no leading 0
        return "971" + digits
    return digits


def normalise_email(raw: str | None) -> str | None:
    # trim + lowercase. empty -> None so the unique index skips it
    if not raw:
        return None
    email = raw.strip().lower()
    return email or None
