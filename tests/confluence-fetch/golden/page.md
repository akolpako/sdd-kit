# Payments — design

https://confluence.example.com/spaces/PAY/pages/123456/Payments+design
Space: Payments (PAY) · Path: Payments Home › Architecture · Version: 7, 2026-10-01, John Doe

# Overview

The **payment service** handles *card* and `SEPA` transfers — see [the glossary](https://confluence.example.com/display/PAY/Glossary) and <https://example.org/spec>.

Owner: @John Doe(tick)

> [!NOTE]
>
> Limits apply to **all** merchants.
>
> Second line.

## Flow & states

1. Create the payment
2. Authorise it
   - 3-D Secure when required
   - otherwise skip
3. Capture

- [x] Design reviewed
- [ ] Load test

```java
public Payment create(Request r) {
    if (r.amount() <= 0) throw new IllegalArgumentException("amount");

    return repo.save(new Payment(r));
}
```

```
POST /payments
  -> 201 Created
```

| State | Next | Note |
| --- | --- | --- |
| NEW | AUTHORISED \| FAILED | first<br>second |
| CAPTURED |  | • a<br>• b |

![flow diagram.png](attachments/flow%20diagram.png)

Spec: [spec.pdf](attachments/spec.pdf), external ![logo](https://cdn.example.org/logo.png)

Ticket: [PAY-42](https://jira.example.com/browse/PAY-42) - Refunds Done

> **Contacts**
>
> Team Payments, line one
> line two

> Quoted text.

---

Details

Hidden details with [a relative link](https://confluence.example.com/pages/viewpage.action?pageId=777).

Unicode: Привет, «quotes», €5, →.
