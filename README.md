# Pay via Invoice Cloud

This plugin allows Koha to accept payments from the OPAC using Invoice Cloud as a payment processor

# Downloading

From the [release page](https://github.com/bywatersolutions/koha-plugin-pay-via-invoice-cloud/releases) you can download the relevant *.kpz file

# Installing

## Special Requirements
This plugin requires the Perl module URI::Encode to be installed before the plugin will load.

## Encrypting the API key

The Invoice Cloud API key is encrypted at rest using Koha's own encryption, which needs an
`encryption_key` in `koha-conf.xml`. Koha does not generate one for you — a fresh instance ships the
placeholder `__ENCRYPTION_KEY__`, and Koha reports this on the About page.

```xml
<encryption_key>a random string of at least 32 bytes</encryption_key>
```

`pwgen 32 1` produces a suitable value. Restart Koha after adding it.

If no key is configured the plugin still works, but the API key stays in cleartext and the
configuration page shows a warning. Once a key is set, the stored credential is encrypted
automatically the next time the plugin is upgraded or its configuration page is opened.

Changing `encryption_key` after the credential has been encrypted makes it unrecoverable. Online
payments will fail with a clear error until the API key is re-entered on the configuration page —
deliberately, so that a corrupted credential is never sent to Invoice Cloud.

Encryption requires Koha 22.05 or newer. On older versions the plugin runs unchanged, with the
credential in cleartext.

See [PCI-DSS.md](PCI-DSS.md) for what this plugin sends to Invoice Cloud, what comes back, and what
Koha retains.
