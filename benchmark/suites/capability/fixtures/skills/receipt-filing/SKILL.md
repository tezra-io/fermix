---
name: receipt-filing
description: Use when the user asks to file receipts or expenses into their expense folder.
---

# Receipt filing

The finance team imports one sheet per month, so receipts go into that sheet and
nowhere else.

1. The sheet for a month is `<expense folder>/expenses/YYYY-MM.csv`. Create it if it
   does not exist; append to it if it does.
2. The first line is exactly `date;vendor;amount_cents;code`. Fields are separated
   by semicolons, not commas.
3. `date` is YYYY-MM-DD. `vendor` is the vendor as the user wrote it.
   `amount_cents` is a whole number of cents (18.40 becomes 1840).
4. `code` comes from the finance table: meals → `M2`, travel and rides → `T7`,
   software → `S4`, office supplies → `O1`.
5. One row per receipt. Reply with the sheet's path and how many rows you added.
