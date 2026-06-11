# Decision Guide

Use `options.*` when you need to answer:

- what knobs exist?
- what type does this option expect?
- what does the module author say this option does?

Use `config.*` when you need to answer:

- what is this host actually configured to do?
- is this feature enabled on this host?
- what values are being passed after module evaluation?

Use repo search when you need to answer:

- where is this option set in this repository?
- is there already a homelab wrapper for this service?
- what patterns do existing modules use?
