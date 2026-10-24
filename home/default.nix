{ lib, uiop, ... }:
[
  {
    name = "index";
    source = ./index.md;
    title = "Salty Dragons";
    css = "index.css";
    homelink = false;
  }
]
++ lib.optional (builtins.pathExists ../cal/calendar.md) {
  name = "calendar";
  source = ../cal/calendar.md;
  title = "Salty Dragons: Game Calendar";
  css = "calendar.css";
  filter = uiop.calendarHtmlFilter;
  homelink = "index.html";
}
