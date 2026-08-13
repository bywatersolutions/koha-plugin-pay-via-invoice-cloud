# PCI DSS scoping statement — Pay via Invoice Cloud

This document describes what data the **Pay via Invoice Cloud** Koha plugin sends to Invoice Cloud,
what Invoice Cloud sends back, and what Koha retains.

It is a factual description of the plugin's behaviour at the commit named in section 9. It is not a
certification, and it does not determine any library's PCI DSS obligations — a library that accepts
card payments is a merchant and has obligations regardless of what Koha does. What this document
establishes is whether Koha itself sits inside the cardholder data environment. Your acquirer and
your assessor decide the rest.

Every code reference links to the exact line on GitHub, pinned to the reviewed commit, so any claim
here can be checked against the source it was drawn from.

---

## 1. Summary

| Assertion | Determination |
|---|---|
| Does this plugin **accept** cardholder data (PAN, CVV/CVC/CID, expiry date, track or chip data, PIN)? | **No** |
| Does this plugin **transmit** cardholder data to any system? | **No** |
| Does this plugin **store** cardholder data? | **No** |
| Does this plugin store any **card-derived** data (card brand, truncated PAN, authorisation code)? | **Yes — card brand only, in application logs. See §5.2.** |
| Does the patron ever enter card details into a page served by Koha? | **No** |
| Does any Koha-served page frame, embed, script, or otherwise affect the processor's card-entry page? | **No** |

**Determination: Koha is outside the cardholder data environment, with the caveats below.**

A patron who chooses to pay library fees online leaves the Koha catalogue entirely and is sent to a
payment page hosted and operated by Invoice Cloud. Card details are typed into that page, travel to
Invoice Cloud, and never reach Koha or ByWater Solutions' servers. Koha does not host, frame, or
script that page — it only links to it. When the payment completes, Invoice Cloud notifies Koha that
a payment of a given amount succeeded, and Koha marks the selected fees as paid.

### Caveats

- Invoice Cloud's payment notification includes a `CardType` field carrying the **card brand** (for
  example `VISA`). The plugin never reads this field, but a debug logging statement captures the
  entire notification, so the card brand is written to the Koha application log. Card brand on its
  own is not cardholder data — it is not a PAN, and it carries no account number, expiry, or
  authentication value — so this does not place Koha inside the cardholder data environment. It is
  recorded here because a reader who greps the logs will find it, and should find it documented.
  See §5.2 and §8.
- The plugin captures **whatever Invoice Cloud posts**, not only the fields Invoice Cloud's
  integration contract declares. The declared contract contains no cardholder data. See §7.

### Two terms that look like card data and are not

**Koha's `cardnumber` is a library card barcode, not a payment card number.** Koha stores each
patron's library card barcode in `borrowers.cardnumber`. It is the number printed on the plastic
card used to borrow books. It is not a PAN and is not cardholder data. This plugin does not transmit
or store it in any case.

**A payment type of `CREDITCARD` on an accountline is a bookkeeping label.** It records that the
patron paid by card *somewhere*. It is a category name in Koha's accounting and does not imply that
card data is stored.

---

## 2. How a payment works

1. The patron selects fees to pay in the OPAC and confirms. Koha calls the plugin's
   [`opac_online_payment_begin`][pm60] hook.
2. **Koha server** generates a one-time token and [records it][pm82-87] against the patron and the
   selected accountlines.
3. **Koha server** [POSTs an invoice-provisioning payload][pm133-142] to
   `https://www.invoicecloud.com/cloudpaymentsapi/v2`, authenticated with an HTTP Basic API key.
   This call creates an invoice record. **It carries no card data** — no card has been presented at
   this point in the flow.
4. **Invoice Cloud** returns a hosted payment URL, read from [`Data.CloudPaymentURL`][pm150].
5. **Patron's browser** [follows a link][begin82] to that URL and the patron enters their card
   details on Invoice Cloud's page. Koha is not involved in this step and receives nothing from it.
6. **Invoice Cloud** POSTs the result to `/api/v1/contrib/invoicecloud/payment` on the Koha server
   ([`handle_payment`][api9]).
7. **Koha server** looks up the token, resolves the accountlines, and [credits the payment][api68-75]
   via `Koha::Account->pay`. The token row is [deleted in the same transaction][api66].
8. **Patron's browser** is returned to `opac-account-pay-return.pl`, which
   [renders a confirmation][pm163].

```
  Patron browser          Koha (ByWater)              Invoice Cloud
        |                       |                           |
        |--- select fees ------>|                           |
        |                       |--- provision invoice ---->|   no card data
        |                       |<-- CloudPaymentURL -------|
        |<-- link to that URL --|                           |
        |--------------------- card details --------------->|   Koha not involved
        |<-------------------- receipt ---------------------|
        |                       |<-- payment notification --|   no card data
        |<-- confirmation ------|                           |
```

### Classification legend

| Value | Meaning |
|---|---|
| `CHD` | Cardholder data: PAN, cardholder name as it appears on the card, expiry, service code |
| `SAD` | Sensitive authentication data: full track data, CVV/CVC/CID, PIN or PIN block |
| `Card-derived` | Derived from a card but not CHD: card brand, truncated PAN, authorisation code |
| `Patron PII` | Personally identifying patron data: name, address, email, telephone |
| `Patron identifier` | Internal or library identifier: `borrowernumber`, library card barcode |
| `Financial` | Amounts, fee descriptions, accountline identifiers |
| `Opaque token` | A value with no meaning outside this transaction |
| `Non-personal` | Configuration, timestamps, URLs, status codes |

---

## 3. Data sent to the payment processor

**Transport:** HTTPS POST, JSON body, initiated by the Koha server (not the browser)
**Endpoint:** [`https://www.invoicecloud.com/cloudpaymentsapi/v2`][pm133]
**Authentication:** HTTP Basic, API key [base64-encoded][pm134] and [set as a header][pm138]

Payload constructed at [`PayViaInvoiceCloud.pm:97-130`][pm97-130].

| Field | Source in Koha | Classification | Purpose | Code |
|---|---|---|---|---|
| `CreateCustomerRecord` | constant `true` | Non-personal | Asks Invoice Cloud to create a customer record | [`:98`][pm98] |
| `Customers[0].AccountNumber` | `borrowers.borrowernumber` | Patron identifier | Correlates the Invoice Cloud customer to the patron | [`:101`][pm101] |
| `Customers[0].Name` | `borrowers.firstname` + `surname` | Patron PII | Names the payer on the hosted page | [`:102`][pm102] |
| `Customers[0].Address` | `borrowers.streetnumber` + `address` | Patron PII | Billing address | [`:103`][pm103] |
| `Customers[0].City` | `borrowers.city` | Patron PII | Billing address | [`:105`][pm105] |
| `Customers[0].State` | `borrowers.state` | Patron PII | Billing address | [`:106`][pm106] |
| `Customers[0].Zip` | `borrowers.zipcode` | Patron PII | Billing address | [`:107`][pm107] |
| `Customers[0].EmailAddress` | `first_valid_email_address` | Patron PII | Receipt delivery | [`:108`][pm108] |
| `Invoices[0].InvoiceNumber` | plugin [token][pm81], `B<borrowernumber>T<epoch>` | Opaque token | Correlates the notification back to the fees | [`:112`][pm112] |
| `Invoices[0].TypeID` | plugin config `invoice_type_id` | Non-personal | Invoice Cloud invoice type | [`:113`][pm113] |
| `Invoices[0].BalanceDue` | sum of `accountlines.amountoutstanding` | Financial | Amount to collect | [`:114`][pm114], computed [`:89-90`][pm89-90] |
| `Invoices[0].CCServiceFee` | plugin config `cc_service_fee` | Non-personal | Convenience fee | [`:115`][pm115] |
| `Invoices[0].ACHServiceFee` | plugin config `cc_service_fee` | Non-personal | Convenience fee | [`:116`][pm116] |
| `Invoices[0].DueDate` | today | Non-personal | Invoice date | [`:117`][pm117] |
| `Invoices[0].InvoiceDate` | today | Non-personal | Invoice date | [`:118`][pm118] |
| `AllowSwipe` | constant `false` | Non-personal | **Disables card-present / swipe capture** | [`:123`][pm123] |
| `AllowCCPayment` | constant `true` | Non-personal | Permits card payment | [`:124`][pm124] |
| `AllowACHPayment` | constant `false` | Non-personal | Disallows bank transfer | [`:125`][pm125] |
| `ReturnURL` | OPAC base URL + token | Non-personal | Where to send the patron afterwards | [`:126`][pm126], built [`:92-93`][pm92-93] |
| `PostBackURL` | OPAC base URL | Non-personal | Where to send the notification | [`:127`][pm127], built [`:94-95`][pm94-95] |
| `BillerReference` | `borrowers.borrowernumber` | Patron identifier | Echoed back in the notification | [`:128`][pm128] |
| `ViewMode` | constant `0` | Non-personal | Hosted page display mode | [`:129`][pm129] |

**Cardholder data in this table: none.** No PAN, CVV, expiry, track, or PIN field is constructed
anywhere in this plugin. [`AllowSwipe => JSON::false`][pm123] additionally disables card-present
capture on the hosted page.

**No itemised fee descriptions are transmitted** — only the summed `BalanceDue`. Invoice Cloud is
not told what the patron was fined for.

This call is made server-to-server, so none of the above appears in a URL, in browser history, or in
a `Referer` header.

---

## 4. Data received from the payment processor

**Transport:** HTTPS POST from Invoice Cloud to `/api/v1/contrib/invoicecloud/payment`, parameters
in the query string ([`openapi.json`][oa], handler [`API.pm:9`][api9])
**Authentication of this channel:** None — the endpoint accepts unauthenticated requests. See §8.

Eighteen parameters are [declared][oa9-118]. The handler reads
[all posted parameters, declared or not][api12].

| Field | Classification | Read by the plugin? | Persisted? | Where | Code |
|---|---|---|---|---|---|
| `BillerReference` | Patron identifier | Yes | No | — | [`API.pm:15`][api15] |
| `InvoiceNumber` | Opaque token | Yes | No (used to delete the token row) | — | [`API.pm:16`][api16] |
| `PaymentAmount` | Financial | Yes | Yes, as the credit amount | `accountlines.amount` | [`API.pm:17`][api17], [`:70`][api70] |
| `Approved` | Non-personal | Yes | No | — | [`API.pm:18`][api18] |
| `CardType` | **Card-derived** (card brand) | No — accepted but never read | **Logged only** | Application log, §5.2 | [`openapi.json:89`][oa89] |
| `CustomerName` | Patron PII | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:35`][oa35] |
| `CustomerAddress` | Patron PII | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:41`][oa41] |
| `CustomerCity` | Patron PII | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:47`][oa47] |
| `CustomerState` | Patron PII | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:53`][oa53] |
| `CustomerZip` | Patron PII | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:59`][oa59] |
| `RemoteIP` | Patron PII | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:113`][oa113] |
| `PaymentGUID` | Opaque token | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:65`][oa65] |
| `BillerGUID` | Opaque token | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:11`][oa11] |
| `PaymentDate` | Non-personal | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:17`][oa17] |
| `PaymentDescription` | Financial | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:77`][oa77] |
| `PaymentTypeID` | Non-personal | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:83`][oa83] |
| `PaymentMessage` | Non-personal | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:95`][oa95] |
| `ConvenienceFee` | Financial | No — accepted but never read | Logged only | Application log, §5.2 | [`openapi.json:107`][oa107] |

**Cardholder data in this table: none.** `CardType` carries the card brand only. No PAN — full or
truncated — no expiry, no CVV, and no authorisation code appears in the declared contract or is read
by the plugin.

The plugin also parses Invoice Cloud's response to the provisioning call of §3, but reads only
[`Data.CloudPaymentURL`][pm150] from it. The full response body is logged; see §5.2.

---

## 5. What Koha stores, and for how long

### 5.1 Database

| Store | Field | Contents | Classification | Written when | Deleted when | Retention |
|---|---|---|---|---|---|---|
| `cloud_invoice_plugin_tokens` | `token` | `B<borrowernumber>T<epoch>` | Patron identifier | Checkout begins ([`:82-87`][pm82-87]) | On notification, approved ([`API.pm:66`][api66]) or declined ([`API.pm:26`][api26]); on patron deletion via `ON DELETE CASCADE` | **Indefinite for abandoned checkouts.** See §5.4 |
| `cloud_invoice_plugin_tokens` | `created_on` | Timestamp | Non-personal | Checkout begins | As above | As above |
| `cloud_invoice_plugin_tokens` | `borrowernumber` | `borrowers.borrowernumber` | Patron identifier | Checkout begins | As above | As above |
| `cloud_invoice_plugin_tokens` | `accountline_ids` | Comma-joined `accountlines_id` list | Financial | Checkout begins | As above | As above |
| `accountlines` | `note` | The literal string `Paid via InvoiceCloud` | Non-personal | Payment credited ([`API.pm:71`][api71]) | With the accountline | Per the library's Koha retention settings |
| `accountlines` | `amount` | `PaymentAmount` from the notification | Financial | Payment credited ([`API.pm:70`][api70]) | With the accountline | Per the library's Koha retention settings |

Table [defined at `PayViaInvoiceCloud.pm:239-255`][pm239-255].

**No cardholder data and no card-derived data is written to the database.** The `accountlines.note`
is a fixed literal — it carries no transaction identifier, no card brand, and no authorisation code.
See §8 for the audit-trail consequence of that.

### 5.2 Logs

Every statement below writes to the Koha application error log (`plack-error.log`, or the Apache
error log depending on deployment). All are unconditional: [`$ENABLE_DEBUGGING = 1`][pm37] is
declared but is never checked anywhere, so no configuration disables them.

| Statement | Location | Enabled by default | Contents | Classification |
|---|---|---|---|---|
| `warn "PARAMS: " . Dumper($params)` | [`API.pm:13`][api13] | Yes | **The entire inbound notification**, including `CardType`, `CustomerName`, `CustomerAddress`, `CustomerCity`, `CustomerState`, `CustomerZip`, `PaymentGUID`, `RemoteIP` | **Card-derived**, Patron PII, Financial |
| `warn "POST DATA: " . Dumper($data)` | [`PayViaInvoiceCloud.pm:131`][pm131] | Yes | The entire outbound payload of §3 — patron name, street address, city, state, zip, email | Patron PII, Financial |
| `warn "REQUEST: " . $req->as_string` | [`PayViaInvoiceCloud.pm:144`][pm144] | Yes, on provisioning failure only | The full HTTP request **including the `Authorization: Basic <api key>` header** | Credential, Patron PII |
| `warn "RESPONSE: " . $response->as_string` | [`PayViaInvoiceCloud.pm:145`][pm145] | Yes, on provisioning failure only | The full HTTP response body | Non-personal |
| `warn "RESPONSE MESSAGE: " . Dumper($message)` | [`PayViaInvoiceCloud.pm:149`][pm149] | Yes | The full parsed provisioning response | Non-personal |
| `warn "TOKEN: " . Dumper($token_hr)` | [`PayViaInvoiceCloud.pm:181`][pm181] | Yes | Token row: token, borrowernumber, accountline ids | Patron identifier, Financial |
| `warn "ACCOUNTLINE IDS: " . Dumper(...)` | [`API.pm:33`][api33] | Yes | Accountline ids | Financial |
| `warn "ACCOUNTLINES TO PAY: " . Dumper($_->unblessed)` | [`API.pm:60-61`][api60-61] | Yes | **Full accountline rows** — borrowernumber, itemnumber, amounts, fee descriptions, existing notes | Patron identifier, Financial |
| `warn "PAYMENT: " . Dumper($payment)` | [`API.pm:79`][api79] | Yes | Payment result | Financial |
| `warn "TOKEN: $token"`, `warn "PATRON: $patron"`, `warn "ACCOUNT: $account"` | [`:20`][api20], [`:43`][api43], [`:53`][api53] | Yes | Token, object references | Patron identifier |

This is the only place in the plugin where card-derived data (the `CardType` brand) comes to rest.

**Log retention:** log files are rotated and removed by the host operating system's `logrotate`
configuration, not by this plugin. The plugin has no control over, and makes no guarantee about, how
long log contents persist. For a ByWater-hosted instance, the applicable policy is ByWater's
platform log retention policy.

*Note:* `Data::Dumper` is not imported by either module, so these statements depend on Koha core
having loaded it. Where it has not been loaded they raise a runtime error instead of writing a log
line. Either way, no cardholder data is involved.

### 5.3 Configuration and credentials

Stored via [`store_data`][pm225-231], which writes to Koha's `plugin_data` table.

| Credential | Stored in | Protection at rest | Visible to | Code |
|---|---|---|---|---|
| `api_key` | Koha `plugin_data` | None — cleartext | Staff with the `plugins` permission | [`:227`][pm227] |
| `invoice_type_id` | Koha `plugin_data` | None — cleartext | As above | [`:228`][pm228] |
| `cc_service_fee` | Koha `plugin_data` | None — cleartext | As above | [`:229`][pm229] |

The configuration form [submits with `method='get'`][conf15] and renders the API key in a
[`type="text"` field][conf22]. Saving the configuration therefore places the API key in the staff
member's browser URL, browser history, and the web server access log. See §8.

The API key is [base64-encoded][pm134] for HTTP Basic authentication. Base64 is an encoding, not
encryption, and provides no protection.

**No cardholder data is held in configuration.**

### 5.4 Retention and disposal

- **Scheduled purge:** None. This plugin ships no cron job, TTL, or cleanup routine.
- **Removed on payment notification:** the `cloud_invoice_plugin_tokens` row, whether the payment was
  [approved][api66] or [declined][api26].
- **Records that accumulate:** token rows for checkouts the patron abandoned before Invoice Cloud
  sent any notification. The `created_on` column exists but nothing reads it, and no code ages rows
  out.
- **On patron deletion:** token rows are removed by the [`ON DELETE CASCADE` foreign key][pm247-248].
  This is the only automatic reaper.
- **On plugin uninstall:** the table is **retained** — [`uninstall()` is a bare `return 1`][pm260-262].
- **Cardholder data retained:** **None.** No cardholder data is stored, so there is none to retain or
  dispose of.
- **Card-derived data retained:** card brand, in application logs only, for as long as the host's log
  rotation policy keeps them.

---

## 6. Patron personal data (outside PCI scope)

The data below is not cardholder data and is outside PCI DSS scope. It is documented here because it
is within scope of library patron-record confidentiality obligations, and because customers ask
about it in the same breath.

| Element | Sent to Invoice Cloud | Received back | Stored by this plugin | Retention |
|---|---|---|---|---|
| Patron name | Yes — §3 | Yes, as `CustomerName` | Logs only — §5.2 | Host log rotation policy |
| Postal address, city, state, zip | Yes — §3 | Yes, as `CustomerAddress` etc. | Logs only — §5.2 | Host log rotation policy |
| Email address | Yes — §3 | No | Logs only — §5.2 | Host log rotation policy |
| Telephone number | No | No | No | Not applicable |
| Library card barcode | No | No | No | Not applicable |
| `borrowernumber` | Yes — §3 | Yes, as `BillerReference` | Yes — `cloud_invoice_plugin_tokens` | Until notification or patron deletion |
| Itemised fee descriptions | **No** — only the summed balance is sent | No | Logs only, via the [accountline dump][api60-61] | Host log rotation policy |
| Patron IP address | No | Yes, as `RemoteIP` | Logs only — §5.2 | Host log rotation policy |

Fee descriptions in Koha can name the borrowed item, which makes them sensitive under most library
confidentiality policies and under several state library-record statutes. They are **not** sent to
Invoice Cloud. They do appear in the application log via the [accountline dump][api60-61].

Once transmitted, Invoice Cloud's handling of this data is governed by their privacy policy and the
library's agreement with them, not by this plugin.

---

## 7. Open questions

| Question | Why the code cannot answer it | Evidence needed | Effect on §1 |
|---|---|---|---|
| Does Invoice Cloud's payment notification ever include fields beyond the eighteen [declared][oa9-118]? | The handler reads [every posted parameter][api12] rather than only the declared set, and [logs all of them][api13]. The source therefore cannot bound what arrives. | Invoice Cloud's postback integration specification. | None on rows 1–3: the plugin never requests card data and Invoice Cloud's declared contract contains none. Row 4 would change if Invoice Cloud posts undeclared card-derived fields, since the log statement captures everything posted. |

---

## 8. Known limitations

These bear on the claims made in this document. They are recorded factually; none of them involves
cardholder data.

| Item | Location | Bearing on this document | Status |
|---|---|---|---|
| The payment notification endpoint declares no `x-koha-authorization` block and verifies no shared secret or signature, and the credited amount is taken from the caller-supplied `PaymentAmount` without reconciliation against the accountlines' outstanding total. | [`openapi.json`][oa], [`API.pm:12`][api12], [`:17`][api17], [`:70`][api70] | Does not affect the cardholder data determination in §1 — no card data is involved. Affects the integrity of the payment record. | Open |
| Debug logging is unconditional. [`$ENABLE_DEBUGGING`][pm37] is declared but never checked, so patron PII and the inbound card brand are written to the application log on every transaction. | [`pm:131`][pm131], [`API.pm:13`][api13], [`:60-61`][api60-61] | This is what makes row 4 of §1 read "Yes". | Open |
| On provisioning failure the full HTTP request, including the `Authorization: Basic <api key>` header, is written to the application log. | [`PayViaInvoiceCloud.pm:144`][pm144] | Credential exposure, not cardholder data. | Open |
| The configuration form submits by `GET` with the API key in a plain text field, placing it in staff browser URLs, browser history, and web server access logs. | [`configure.tt:15`][conf15], [`:22`][conf22] | Credential exposure, not cardholder data. | Open |
| Token rows for abandoned checkouts are never purged; `created_on` is recorded but never read. | [`PayViaInvoiceCloud.pm:82-87`][pm82-87] | Affects §5.4. No cardholder data is involved. | Open |
| The plugin's table is not dropped on uninstall. | [`PayViaInvoiceCloud.pm:260-262`][pm260-262] | Affects §5.4. | Open |
| `accountlines.note` is the fixed literal `Paid via InvoiceCloud` and records no transaction reference, so a credit in Koha cannot be traced back to a specific Invoice Cloud payment from Koha's own records. | [`API.pm:71`][api71] | Affects §5.1. Reconciliation depends entirely on Invoice Cloud's records. | Open |

---

## 9. What was reviewed

Reviewed at commit [`46f06e67143ab40c5b8c99b213b9c60e9ce279d0`][commit], version `v1.2.1`, on
2026-08-13.

The reviewed commit is the commit the review was performed against — the parent of the commit that
adds this file. Every code link in this document is pinned to that commit, so the lines cited are the
lines that were read, regardless of later changes.

| File | Checked for |
|---|---|
| [`PayViaInvoiceCloud.pm`][pm] | Outbound payload construction, provisioning call, return handling, install schema, configuration |
| [`PayViaInvoiceCloud/API.pm`][api] | Inbound endpoint, channel authentication, payment crediting, logging |
| [`PayViaInvoiceCloud/openapi.json`][oa] | Declared inbound parameters, authorisation requirements |
| [`PayViaInvoiceCloud/opac_online_payment_begin.tt`][begin] | Values rendered into pages served to patrons; how the patron reaches the hosted page |
| [`PayViaInvoiceCloud/configure.tt`][conf] | Values rendered into pages served to staff; form submission method |

**Not reviewed:** build tooling, dependency trees, and Koha core. Koha core's own handling of
`accountlines` is outside this document. Invoice Cloud's own systems and PCI DSS validation status
are outside this document — confirm those directly with Invoice Cloud.

**Re-review is required when any of these change:** the outbound payload construction, the API
controller, `openapi.json`, the install or upgrade schema, or any logging statement in a payment code
path.

---

## 10. Review history

| Date | Version | Commit | Reviewer | Change |
|---|---|---|---|---|
| 2026-08-13 | v1.2.1 | [`46f06e6`][commit] | Kyle M Hall | Initial review |

---

<!--
Code links are pinned to the reviewed commit, so the lines cited stay the lines
that were read.

To re-review at a new commit:
  1. Replace every occurrence of the 40-character sha (this block, plus the
     display text in §9 and the commit link in §10).
  2. Replace the short sha in the §10 review-history table.
  3. Re-derive the line numbers — they are the part that rots. Each label
     encodes its own line span: [pm131] is PayViaInvoiceCloud.pm line 131,
     [api60-61] is API.pm lines 60 to 61, [oa89] is openapi.json line 89.
     Prefixes: pm = PayViaInvoiceCloud.pm, api = API.pm, oa = openapi.json,
     begin = opac_online_payment_begin.tt, conf = configure.tt.
-->

[api]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm
[api12]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L12
[api13]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L13
[api15]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L15
[api16]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L16
[api17]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L17
[api18]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L18
[api20]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L20
[api26]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L26
[api33]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L33
[api43]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L43
[api53]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L53
[api60-61]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L60-L61
[api66]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L66
[api68-75]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L68-L75
[api70]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L70
[api71]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L71
[api79]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L79
[api9]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/API.pm#L9
[begin]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/opac_online_payment_begin.tt
[begin82]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/opac_online_payment_begin.tt#L82
[commit]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/commit/46f06e67143ab40c5b8c99b213b9c60e9ce279d0
[conf]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/configure.tt
[conf15]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/configure.tt#L15
[conf22]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/configure.tt#L22
[oa]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json
[oa107]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L107
[oa11]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L11
[oa113]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L113
[oa17]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L17
[oa35]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L35
[oa41]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L41
[oa47]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L47
[oa53]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L53
[oa59]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L59
[oa65]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L65
[oa77]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L77
[oa83]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L83
[oa89]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L89
[oa9-118]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L9-L118
[oa95]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud/openapi.json#L95
[pm]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm
[pm101]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L101
[pm102]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L102
[pm103]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L103
[pm105]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L105
[pm106]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L106
[pm107]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L107
[pm108]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L108
[pm112]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L112
[pm113]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L113
[pm114]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L114
[pm115]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L115
[pm116]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L116
[pm117]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L117
[pm118]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L118
[pm123]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L123
[pm124]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L124
[pm125]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L125
[pm126]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L126
[pm127]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L127
[pm128]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L128
[pm129]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L129
[pm131]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L131
[pm133]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L133
[pm133-142]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L133-L142
[pm134]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L134
[pm138]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L138
[pm144]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L144
[pm145]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L145
[pm149]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L149
[pm150]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L150
[pm163]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L163
[pm181]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L181
[pm225-231]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L225-L231
[pm227]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L227
[pm228]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L228
[pm229]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L229
[pm239-255]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L239-L255
[pm247-248]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L247-L248
[pm260-262]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L260-L262
[pm37]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L37
[pm60]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L60
[pm81]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L81
[pm82-87]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L82-L87
[pm89-90]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L89-L90
[pm92-93]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L92-L93
[pm94-95]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L94-L95
[pm97-130]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L97-L130
[pm98]: https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/blob/46f06e67143ab40c5b8c99b213b9c60e9ce279d0/Koha/Plugin/Com/ByWaterSolutions/PayViaInvoiceCloud.pm#L98
