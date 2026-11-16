"""Unit tests for the normaliser. Run: python -m unittest (or pytest)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from app.normalise import normalise_email, normalise_phone  # noqa: E402


class PhoneTests(unittest.TestCase):
    def test_uae_formats_collapse_to_same_value(self):
        for raw in ["050 123 4567", "+971 50 123 4567", "00971501234567",
                    "+971-50-123-4567", "(050) 1234567", "501234567"]:
            self.assertEqual(normalise_phone(raw), "971501234567", raw)

    def test_empty_is_none(self):
        self.assertIsNone(normalise_phone(None))
        self.assertIsNone(normalise_phone(""))
        self.assertIsNone(normalise_phone("  - "))

    def test_non_uae_kept_as_digits(self):
        self.assertEqual(normalise_phone("+44 20 7946 0000"), "442079460000")


class EmailTests(unittest.TestCase):
    def test_trim_and_lowercase(self):
        self.assertEqual(normalise_email("  Jane.Doe@Example.COM "), "jane.doe@example.com")

    def test_empty_is_none(self):
        self.assertIsNone(normalise_email(None))
        self.assertIsNone(normalise_email("   "))


if __name__ == "__main__":
    unittest.main()
