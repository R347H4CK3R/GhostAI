# Unified assistant, first integration step

Goal: preserve both apps while allowing selected Luma notes/checklists to enter Veyra's existing previewed memory importer.
Architecture: retain dev.asterionveyra.assistant and its native voice/GitHub client. Keep app.luma.personal installed until verified migration. Independently implement a local compatibility converter; never copy private Luma source into public GhostAI. A later native planner uses the same reviewed runner, not a second job runtime.
Constraints: no actual user data, network calls, credential setup, job cutover or release publication in this step. Checklist items become explicitly labeled reference notes, not executable jobs or native tasks. Encrypted input remains encrypted and unsupported here. Voice remains available through existing turn-taking/Siri entry, subject to OS/device/permission limits; text remains accessible.

- [ ] Write synthetic conversion/rejection tests and observe missing implementation.
- [ ] Implement bounded, strict local JSON conversion, stable identifiers, safe errors and exclusive output creation.
- [ ] Run full tests, document local import review and remaining native/device gates.

Review focus: duplicate keys/IDs, malformed boolean/version/date, credential-like content, oversize input, source/output preservation. All reject safely. Generated files contain private content if user later runs this on their data and must never be uploaded to a repository.
