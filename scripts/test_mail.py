import smtplib
import ssl
import sys
import os
from email.message import EmailMessage
from email.utils import make_msgid, formatdate

from env_loader import load_env


# --- Load secrets from .env ---
load_env()

try:
    SMTP_SERVER = os.environ["SMTP_SERVER"]
    SMTP_PORT = int(os.environ["SMTP_PORT"])
    EMAIL_USER = os.environ["EMAIL_USER"]
    EMAIL_PASS = os.environ["EMAIL_PASS"]
except KeyError as e:
    sys.exit(f"Missing env var: {e}")


def send_test(recipient_email: str) -> None:
    msg = EmailMessage()

    msg["Subject"] = "Important Service Infrastructure Update | Dreamseed Online"
    msg["From"] = f"Dreamseed Administration <{EMAIL_USER}>"
    msg["To"] = recipient_email
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain="dreamseed.online")

    body = """Dear Valued Partner,

We are writing to formally notify you regarding the successful optimization of our communication protocols. As part of our ongoing commitment to data integrity and secure information exchange, our technical team has finalized the deployment of updated mail server configurations.

This message serves as a formal verification of the end-to-end encryption and delivery consistency between our primary node and your designated receiving server. No further action is required on your part at this time.

We appreciate your continued trust in the Dreamseed platform and our digital infrastructure. Should you have any inquiries regarding our security standards or service availability, please feel free to visit our official documentation portal.

Best regards,

Compliance & Infrastructure Team
Dreamseed.online | Secure Operations Division
--------------------------------------------------
This is an automated system notification.
"""
    msg.set_content(body)

    msg["Precedence"] = "bulk"
    msg["X-Priority"] = "3 (Normal)"

    print(f"--- Initiating secure transfer to: {recipient_email} ---")
    try:
        context = ssl.create_default_context()
        with smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=30) as server:
            server.starttls(context=context)
            server.login(EMAIL_USER, EMAIL_PASS)
            server.send_message(msg)
        print(f"[SUCCESS] Transmission completed for {recipient_email}")
    except Exception as e:
        print(f"[ERROR] Critical failure: {e}")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        send_test(sys.argv[1])
    else:
        print("Usage: python3 test_mail.py <recipient_email>")
