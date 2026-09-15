# Done

You told a port failure apart from an endpoint failure. Same `Connection refused` a black hole can produce — but the **populated** EndpointSlice ruled out the selector and pointed at the port instead. The Service forwarded to `targetPort: 8080` while nginx listened on 80, so traffic reached a Pod and was rejected by its kernel. `containerPort` declaring 80 changed nothing — only the listener and the `targetPort` decide whether bytes flow.

That completes the connectivity differential: **the name didn't resolve (DNS), the Service had no backends (selector/readiness), or the backend port had no listener (`targetPort`). The client error says it broke; the EndpointSlice and the DNS answer say where.**

**Next:**

- Check your path against [`ANSWER-KEY.md`](../ANSWER-KEY.md).
- For the *why*, see [`LESSON.md`](../LESSON.md) § Ports, and the Recap.
- You've finished M04's break/fix set. Next module: **M05 — Storage** (volumes, PV/PVC, StorageClass, access modes).
