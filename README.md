gnome-org-next-schedule
=======================

A gnome-shell extension to display your next schedule.
This adds a new widget to the status bar with a countdown until the next event
and triggers a notification five minutes before.

![screenshot](./screenshot.png)


# Usage

The extension loads a list of events from `~/.local/share/org-gnome-next-schedule/events`
using the following format: `<date_iso_8601> <event title>`.

The events list can be generated using [org-ql][org-ql]:

```emacs-lisp
(defun tc/mk-next-meeting-query ()
  "The next meeting query."
  '(and (not (or (todo "DONE") (todo "CANCELLED"))) (scheduled :from now)))

;; see: https://github.com/alphapapa/org-ql/issues/397
(defun tc/compare-entry (b a)
  "Order entry A and B so that they appears from newest to oldest.
This is like org-ql--date< but considering closed date too."
  (cl-macrolet ((ts (item)
                  `(or (org-element-property :closed ,item)
                       (org-element-property :deadline ,item)
                       (org-element-property :scheduled ,item))))
    (org-ql--org-timestamp-element< (ts a) (ts b))))

(defun tc/sched-format (item)
  (let* ((properties (cadr item))
         (title (plist-get properties :raw-value))
         (scheduled (plist-get properties :scheduled))
         (ts (format-time-string "%FT%T%z" (org-timestamp-to-time scheduled))))
    (format "%s %s" ts title)))

(defun tc/render-sched ()
  (let* ((entries (org-ql-select '("~/org/projects.org")
                    (tc/mk-next-meeting-query)
                    :action 'element-with-markers
                    :sort 'tc/compare-entry
                    ))
         (formated (mapcar 'tc/sched-format (seq-filter 'not-habits entries)))
         (report (s-unlines (reverse formated))))
    (f-write-text report 'utf-8 "~/.local/share/gnome-org-next-schedule/events")))

;; TODO: call render-sched when the agenda changes
```

… which produces such a file:

```
2024-01-16T10:00:00-0500 Team Daily
```


# Contribute

Contributions are most welcome.

To modify gnome-org-next-schedule, you will need a [PureScript][purescript] toolchain
and the gnome developper tool.
Run the `nix develop` command to setup.

Checkout the [purescript-gjs][purescript-gjs] bindings too.


# Changes

## 0.1

- Initial release.

[purescript]: https://www.purescript.org/
[purescript-gjs]: https://github.com/purescript-gjs/purescript-gjs
[org-ql]: https://github.com/alphapapa/org-ql
