import QtQuick
import "kit"

// FoamyDropdown for settings bound to shell.json. The kit dropdown assigns
// `value` on select, which would replace a caller's binding for good (the
// popup body is kept between opens, so later changes from the bar or CLI
// would no longer show). Bind `current` instead: the binding is restored
// after every selection, so the dropdown always shows the stored setting.
FoamyDropdown {
  id: root
  property string current: ""
  value: current
  onChanged: root.value = Qt.binding(function() { return root.current })
}
