---
generated: 2026-06-09
ticket: ISD-8588
---

# Known Issues — ISD-8588

## Direct ENG Bug Match

**ENG-16911** — "Workflow Child Job Opening Behavior."
- Type: Bug
- Status: **Backlog (Unresolved)**
- Fix Versions: **None assigned**
- Assignee: Rowan Gibbs (rowan.gibbs@itential.com)
- Description: "Observed a change where opening a child job or transformation
  now opens in a new browser window instead of a new tab within the same
  Studio window, causing workflow management and potential data loss issues
  from having multiple unsaved tabs."
- URL: https://itential.atlassian.net/browse/ENG-16911

**Verdict:** ISD-8588 is a direct customer report of the same defect tracked
in ENG-16911. The Engineering bug is in Backlog with no fix version — meaning
no patch has been released yet. This is a KNOWN OPEN BUG.

## Related ISD Tickets

**ISD-9005** — "[ Labs ] childJob done but parent waiting forever" — DIFFERENT
issue (WFE runtime bug, not UI). Resolved. Fixed in Platform-6.4.0 via ENG-22494.

## Related ENG Bugs

**ENG-22494** — "WorkFlow Engine unexplained Memory Spike leading to Hung status
of tasks (Mainly ChildJobs)" — Fixed in Platform-6.4.0. Runtime/WFE issue, not UI.

**ENG-9553** — "Projects: Issues with JSTs used in childJob task" — Fixed in
Platform 6.3.0. Different issue.

## Confluence Knowledge Base

No relevant KB articles, runbooks, or investigation notes found for this
specific UI behavior (child job opening in new window vs new tab).
