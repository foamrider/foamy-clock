import QtQuick
import Quickshell
import Quickshell.Io
import "harness"
import "plugin" as Clock

// The shell goes away (a reload or an exit) while a month refresh runs.
// runtime.py makes the worker hang and the `timeout` wrapper pass no signal
// on, as when Quickshell's kill lands before timeout forwards anything. This
// scene starts the refresh, waits for the worker and quits; runtime.py then
// checks that no helper process of the refresh is left.
// With FOAMY_TEARDOWN=crash the scene does not quit: runtime.py kills the
// shell itself, as a crash would, with the real `timeout` wrapper.
// With FOAMY_TEARDOWN=startup the scene quits as soon as the bridge has
// started, while runtime.py holds it in Python's start-up.
ShellRoot {
  id: shell
  readonly property bool startup: Quickshell.env("FOAMY_TEARDOWN") === "startup"

  FoamyWait {
    id: wait
  }
  FileView {
    id: workerFile
    // The pid file of the worker, or in start-up mode the bridge's.
    path: Quickshell.env("FOAMY_OUT") + (shell.startup ? "/starting" : "/worker")
    blockLoading: true
    printErrors: false
  }

  Component.onCompleted: {
    Clock.ClockService.refresh()
    wait.waitFor(function () {
      workerFile.reload()
      return workerFile.text() !== "" && Clock.ClockService.agendaProcess.running
    }, 10000, function (ok) {
      if (ok && Quickshell.env("FOAMY_TEARDOWN") === "crash") {
        console.log("FOAMY WORKER RUNNING")
        return
      }
      console.log(ok ? "FOAMY DONE" : "FOAMY FAIL the month refresh did not reach its " + (shell.startup ? "bridge" : "worker"))
      Qt.quit()
    })
  }
}
