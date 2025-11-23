; inherits: svelte

((script_element
  (raw_text) @injection.content)
 (#set! injection.language "typescript"))

((script_element
  (start_tag
    (attribute
      (attribute_name) @_lang
      (quoted_attribute_value
        (attribute_value) @_value)))
  (raw_text) @injection.content)
 (#match? @_lang "^lang$")
 (#match? @_value "^(ts|typescript)$")
 (#set! injection.language "typescript"))
