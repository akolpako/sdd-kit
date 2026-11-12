# ABC-7 — Move report generation into its own service

https://jira.example.com/browse/ABC-7

## Solution design

1. Add a new module **report-worker**. It builds a runnable jar:
   - The build file produces an image out of that jar.
   - It keeps the `StartupCondition` start conditions, and `WORKER_GROUP` with them.
   - A nested bullet whose marker spells the level above it.
1. Reconfigure **web-app** to run no worker.

- A list of its own
  - nested under a bullet, two columns in

### Flush heading

> Quoted **text** with colour.

```
  keep   *this*  _as is_
```

A closing paragraph naming SOME_CONST_NAME and **one bold run**.
