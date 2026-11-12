# ABC-123 — Send order confirmations by email

https://jira.example.com/browse/ABC-123
Type: Story · Status: In Progress · Priority: Major · Assignee: Jane Doe · Updated: 2026-10-30

## Goals

- Send a confirmation email when an order is placed
- Keep the existing on-screen confirmation

## Design

As agreed with @jdoe, see ![flow diagram.png](attachments/flow%20diagram.png) and the [spec.pdf](attachments/spec.pdf).
The [old contract](attachments/contract%20v1.docx) stays.

```java
record OrderPlaced(String id) {} // !not-an-image.png!
```

| Field | Required |
| --- | --- |
| id | yes |

Also ![](https://cdn.example.net/logo.png) and ![../../escape.png](attachments/../../escape.png) and ![missing.png](attachments/missing.png).
See [the mail server notes](https://wiki.example.com/mail) and <https://example.com/x_y_z>.
