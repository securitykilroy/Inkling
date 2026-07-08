# Security Policy

## Scope and threat model

Inkling is a native macOS app for writing on your own machine. It has **no
network services, no user accounts, no telemetry, and does not transmit your
documents anywhere**. Its security surface is therefore narrow and local.

The realistic risk is in **parsing files that come from outside**:

- opening `.inkling` documents (Core Data stores),
- importing Word `.docx` files (a custom parser),
- decoding embedded rich text (RTF/RTFD) and images.

A maliciously crafted file of one of these kinds is the plausible threat — a
parser flaw could crash the app or, in the worst case, be exploited. Reports of
that nature are **in scope**.

Out of scope, because Inkling doesn't have them: remote/network attacks,
authentication, server-side issues, and secret/credential handling.

## Supported versions

This is a small project. Only the latest `main` is supported; fixes land there
and are not back-ported to older revisions.

## Reporting a vulnerability

**Please report privately. Do not open a public GitHub issue for a security
problem** — a public issue discloses the flaw before a fix exists.

Preferred channel: GitHub's private vulnerability reporting. Go to the
repository's **Security** tab and click **Report a vulnerability**. This keeps
the report confidential between you and the maintainer.

When reporting, please include:

- a description of the issue and its impact,
- steps to reproduce (a proof-of-concept file, if relevant),
- the affected version or commit.

## What to expect

Inkling is a personal, open-source project maintained on a best-effort basis.
I will acknowledge your report as soon as I reasonably can, investigate, and fix
confirmed issues on `main`. I'll keep you informed of progress and credit you
when a fix ships, unless you'd prefer to stay anonymous. Please allow reasonable
time for a fix before any public disclosure (coordinated disclosure).

## A note for users

As with any document-based app, open `.inkling` and `.docx` files only from
sources you trust.
