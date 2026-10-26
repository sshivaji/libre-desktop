# Acknowledgments and protocol references

Libre Desktop is distributed under AGPL-3.0; see [LICENSE](LICENSE). The app uses Apple's system frameworks. No third-party source packages, Python runtime, or Garmin protocol code are bundled.

The independent LibreLinkUp client was informed by request/response formats documented in [DiaKEM/libre-link-up-api-client](https://github.com/DiaKEM/libre-link-up-api-client) and [nightscout/nightscout-connect](https://github.com/nightscout/nightscout-connect). These include regional hosts, request headers, the hashed Account-Id header, UTC measurement timestamps, trends, and login/connections/graph schemas. No source code or packages from those projects are bundled.

The independent LibreView history client uses protocol details from [skobkars/lvconnect](https://github.com/skobkars/lvconnect), [YtoTech/libreview-data-export](https://github.com/YtoTech/libreview-data-export), and Abbott's publicly served LibreView 3.27.0.42 web application. These informed login, report requests, session authentication, and embedded Daily Log JSON. No source code or packages from those projects are bundled.

See Abbott's [LibreLinkUp guidance](https://www.freestyle.abbott/en-us/support/faq/apps/connecting-with-a-freestyle-libre-user-using-the-librelinkup-app.html) and [LibreView patient guide](https://pat.libreview.io/articles/qsg) for the official services. Libre Desktop is not an Abbott product or an officially supported integration.
