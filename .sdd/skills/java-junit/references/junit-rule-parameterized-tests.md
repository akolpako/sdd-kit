---
title: Parameterized tests for data variation
description: Use when several tests differ only in input/expected values
keywords: parameterized, ParameterizedTest, ValueSource, EnumSource, CsvSource, MethodSource, NullAndEmptySource, data variation, duplication, data driven
---

# Parameterized tests for data variation

When tests differ only in input/expected values, use `@ParameterizedTest`.
Do **not** parameterize when test logic, mock setup, or assertion structure differs between cases.

```java
// ❌ Don't — duplicate tests differing only in the advertising value
@Test void search_bannerAdvertising_returnsBannerResponse() { ... }
@Test void search_videoAdvertising_returnsVideoResponse() { ... }

// ✅ Do
@ParameterizedTest
@EnumSource(Advertising.class)
void search_advertisingFound_returnsMatchingResponse(Advertising advertising) {
    Request request = createRequest(ID);
    givenIdFound(ID);
    givenAdvertisingFound(ID, advertising);

    Response response = processor.search(request);

    assertOkResponse(response, advertising);
}
```
