# Security Policy

## Threat surface (small by design)

Parla is a **100% on-device** app. It has **no backend, no account, and no telemetry**. Your audio and
transcripts never leave your machine. The only outbound network call is a **one-time model download** of
the Whisper CoreML weights (from Hugging Face); everything else runs locally.

That means the attack surface is essentially: the local file handling (imported audio, the history JSON,
the audio cache) and the bundled/third-party binaries (the WhisperKit / MLX / Opus / Ogg
dependencies). There is no server to attack and no user data in transit.

## Supported versions

The latest `main` is the supported version. Fixes land there first.

## Reporting a vulnerability

Please **do not** open a public issue for a security problem. Instead, use GitHub's private
**“Report a vulnerability”** flow (repository → **Security** tab → *Report a vulnerability*), which opens
a private advisory visible only to the maintainer.

Include: what you found, how to reproduce it, and the impact. You'll get an acknowledgement, and a fix or
explanation once it's triaged. Thanks for helping keep Parla safe.
