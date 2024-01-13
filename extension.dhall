let name = "gnome-org-next-schedule"

in  (env:PGS).Extension::{
    , name
    , module = "GnomeOrgNextSchedule"
    , description = "A gnome extension to display the next event."
    , url = "https://github.com/TristanCacqueray/${name}"
    , domain = "tristancacqueray.github.io"
    }
