# Expected Output

The demo should show:

- A fake agent reading a malicious README instruction.
- A blocked shell `.env` read attempt.
- A blocked synthetic network exfiltration attempt.
- A successful `ryk replay --session last --verify`.
- No generated fake secret value in terminal output or ryk audit artifacts.

Exact session IDs and timestamps vary.
