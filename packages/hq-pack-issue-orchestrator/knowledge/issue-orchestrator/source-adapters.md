# Source adapter contract

Every issue source adapter must provide:

- stable source ID and type;
- non-secret locator and tenant ownership;
- eligible root/item rule and excluded event classes;
- immutable identity key for exact idempotency;
- bounded collection window and pagination;
- canonical conversation or issue coordinates;
- normalized title, body, author class, timestamps, status, labels, and links;
- per-entry success or failure detail for batch calls;
- separate read and write capability declarations.

Supported source types are not hardcoded. Typical adapters include GitHub Issues, Linear, Slack roots, email threads, support desks, local Markdown queues, and custom APIs. Use an existing connected app or HQ connection when one is available. A missing adapter is a setup blocker for that source, not permission to scrape or copy credentials.
