gnome-org-next-schedule
=======================

A gnome-shell extension to display your next schedule.
This adds a new widget to the status bar with a countdown until the next event
and triggers a notification five minutes before.

![screenshot](./screenshot.png)

This extension is best used with [org-mode][org-mode] superior scheduling capabilities,
for regular gnome calendar, see <https://github.com/chmouel/gnome-next-meeting-applet>.

# Usage

The extension loads a list of events from `~/.local/share/org-gnome-next-schedule/events`
using the following format: `<date_iso_8601> <event title>`.

The events list can be generated using [org-ql][org-ql]:

```emacs-lisp
(defun tc/mk-next-meeting-query ()
  "The next meeting query."
  '(and (not (done)) (not (habit)) (scheduled :from ,(ts-now))))

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

(defvar tc/schedule-events ""
  "The last schedule render to update the files when it changes.")

(defun tc/render-schedule-events ()
  (let* ((entries (org-ql-select '("~/org/projects.org")
                    (tc/mk-next-meeting-query)
                    :action 'element-with-markers
                    :sort 'tc/compare-entry
                    ))
         (formated (mapcar 'tc/sched-format (seq-filter 'not-habits entries)))
         (report (s-join "\n" (reverse formated))))
    (when (not (string= report tc/schedule-events))
      (setq tc/schedule-events report)
      (f-write-text report 'utf-8 "~/.local/share/gnome-org-next-schedule/events"))))

;; Update schedule events when the agenda is displayed
(add-hook 'org-agenda-mode-hook 'tc/render-schedule-events)
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
[org-mode]: https://orgmode.org/
[org-ql]: https://github.com/alphapapa/org-ql
