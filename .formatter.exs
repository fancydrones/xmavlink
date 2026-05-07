[
  # lib/common.ex is checked-in generated Common dialect output. Keep generated
  # dialect modules out of the formatter gate; regenerate them from MAVLink XML
  # instead of hand-formatting or hand-editing generated code.
  inputs: [
    "mix.exs",
    "config/**/*.{ex,exs}",
    "lib/{mavlink,mavlink_util,mix}/**/*.{ex,exs}",
    "test/**/*.{ex,exs}"
  ]
]
