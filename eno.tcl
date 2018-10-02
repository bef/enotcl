##
## Parser for the declarative ENO language
## see eno-lang.org
##
## source: https://github.com/bef/enotcl
##
##   Copyright 2018 Ben Fuhrmannek <bef@pentaphase.de>
##
##   Licensed under the Apache License, Version 2.0 (the "License");
##   you may not use this file except in compliance with the License.
##   You may obtain a copy of the License at
##
##       http://www.apache.org/licenses/LICENSE-2.0
##
##   Unless required by applicable law or agreed to in writing, software
##   distributed under the License is distributed on an "AS IS" BASIS,
##   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
##   See the License for the specific language governing permissions and
##   limitations under the License.
##
package provide eno 0.1

package require Tcl 8.6

##
namespace eval eno {
	variable tmpstore {}
	namespace ensemble create -subcommands {parse value elements element fieldsets fieldset fields field fieldlists fieldlist sections section sectionfield write}
}

## HELPERS

## helper function to create variables from 'args' with predefined default values
proc ::eno::named_args {default_args} {
	upvar 1 args args
	set args [dict merge $default_args $args]
	foreach k [dict keys $default_args] {
		uplevel 1 [list set $k [dict get $args $k]]
	}
}

## PARSER

## parse | and \ continuation
proc eno::parse_extra {} {
	upvar lines lines lineno lineno
	set result ""
	while {$lineno < [llength $lines]} {
		set next_line [lindex $lines $lineno+1]
		set extra ""
		switch -regexp -matchvar match -- $next_line {
			{^\s*\|\s*(.*?)\s*$} {
				lassign $match -> extra
				set extra "\n$extra"
			}
			{^\s*\\\s*(.*?)\s*$} {
				lassign $match -> extra
				set extra " $extra"
			}
			{^\s*$} -
			{^\s*>} {}
			default {
				break
			}
		}
		append result $extra
		incr lineno
	}
	return $result
}



proc eno::parse {data} {
	set lineno -1
	set lines [split $data \n]
	set result {}
	for {set lineno 0} {$lineno < [llength $lines]} {incr lineno} {
		set line [lindex $lines $lineno]

		switch -regexp -matchvar match -- $line {
			{^\s*>} {
				## comment -> ingore.
				}
			{^\s*$} {
				## empty -> ignore.
				}
			{^\s*(`*)\s*(.*?)\s*\1\s*:\s*(.*?)\s*$} {
				## field
				lassign $match -> _ key value
				append value [parse_extra]
				set type "field"

				if {$value eq "" && $lineno < [llength $lines]} {
					## maybe fieldset or list?
					set next_line [lindex $lines $lineno+1]
					while {true} {
						if {($type eq "fieldset" || $type eq "field") && [regexp -- {^\s*(.*?)\s*=\s*(.*?)\s*$} $next_line -> x_key x_value]} {
							set type "fieldset"
						} elseif {($type eq "list" || $type eq "field") && [regexp -- {^\s*-\s*(.*?)$} $next_line -> x_value]} {
							set type "list"
						} else {
							break
						}
						incr lineno
						append x_value [parse_extra]
						if {$type eq "fieldset"} {
							lappend value $x_key
						}
						lappend value $x_value
						set next_line [lindex $lines $lineno+1]
					}
				}
				lappend result [list $type $key $value]
			}
			{^\s*(#+)\s*(`*)\s*(.*?)\s*\2\s*(?:(<|<<)\s*(.*?)\s*)?$} {
				## sections
				lassign $match -> depth _ value copy template
				set depth [string length $depth]
				append value [parse_extra]
				if {$copy ne ""} {
					lappend result [list section $value $depth [list $copy $template]]
				} else {
					lappend result [list section $value $depth $template]
				}
			}
			{^\s*(`*)\s*(.*?)\s*\1\s*<\s*(.*?)\s*$} {
				## field copy
				lassign $match -> _ key key1
				set found false
				foreach element $result {
					lassign $element type k v
					if {$k eq $key1 && [lsearch -exact {field fieldset list} $type] >= 0} {
						lappend result [list $type $key $v]
						set found true
						break
					}
				}
				if {!$found} {
					throw {ENO TEMPLATE_COPY} "no element found named '$key1'"
				}
			}
			{^\s*(--+)\s*(.*?)\s*$} {
				## block
				lassign $match -> dashes blockname
				set value {}
				while {true} {
					incr lineno
					if {$lineno >= [llength $lines]} {
						throw {ENO MISSING_END_OF_BLOCK} "no matching end for block '$dashes $blockname'"
					}
					set line [lindex $lines $lineno]
					if {[regexp -- {^\s*(--+)\s*(.*?)\s*$} $line -> end_dashes end_blockname] && $dashes eq $end_dashes && $blockname eq $end_blockname} {
						set value [join $value "\n"]
						break
					}
					lappend value $line
				}
				lappend result [list field $blockname $value]
			}
			default {
				throw {ENO UNKNOWN} "unexpected line [expr {$lineno+1}]: $line"
			}
		}
	}
	return [parse_postprocessor $result]
}

proc eno::tmpstore_section {section_name section} {
	variable tmpstore
	# if {[dict exists tmpstore $section_name]} {
	# 	return
	# }
	dict set tmpstore $section_name $section
}

proc eno::tmpstore_empty {} {
	variable tmpstore
	set tmpstore {}
}

## split section into two lists - fields and sections
proc eno::split_section {data} {
	set i 0
	foreach element $data {
		if {[lindex $element 0] eq "section"} { break }
		incr i
	}
	return [list [lrange $data 0 $i-1] [lrange $data $i end]]
}

## serach for element by name
proc eno::get_element {data type name {ret_bool false}} {
	foreach element $data {
		lassign $element el_type arg1 arg2 tmpl
		if {$el_type eq $type && $name eq $arg1} {
			if {$ret_bool} { return true }
			return $element
		}
	}
	if {$ret_bool} { return false }
	return {}
}
proc eno::has_element {data type name} {
	return [get_element $data $type $name true]
}

proc eno::section_copy {section template} {
	lassign [split_section $section] sec_fields sec_sections
	lassign [split_section $template] tmpl_fields tmpl_sections

	set result $sec_fields

	## add missing template fields
	foreach element $tmpl_fields {
		lassign $element el_type arg1 arg2
		if {![has_element $sec_fields $el_type $arg1]} {
			lappend result $element
		}
	}

	lappend result {*}$sec_sections

	## add missing template sections
	foreach element $tmpl_sections {
		lassign $element el_type arg1 arg2
		if {![has_element $sec_sections "section" $arg1]} {
			lappend result $element
		}
	}

	return $result
}

proc eno::section_deepcopy {section template} {
	lassign [split_section $section] sec_fields sec_sections
	lassign [split_section $template] tmpl_fields tmpl_sections

	set result $sec_fields

	## add missing template fields
	foreach element $tmpl_fields {
		lassign $element el_type arg1 arg2
		if {![has_element $sec_fields $el_type $arg1]} {
			lappend result $element
		}
	}

	## process subsections recursively
	foreach element $tmpl_sections {
		lassign $element el_type arg1 arg2
		if {![has_element $sec_sections "section" $arg1]} {
			lappend result $element
		} else {
			lassign [get_element $sec_sections "section" $arg1] -> name subsection
			lappend result [list section $arg1 [section_deepcopy $subsection $arg2]]
		}
	}

	## add subsections not in template
	foreach element $sec_sections {
		lassign $element el_type arg1 arg2
		if {![has_element $tmpl_sections "section" $arg1]} {
			lappend result $element
		}
	}

	return $result
}

## process section copies and deep copies
proc eno::process_templates {section tmpl} {
	variable tmpstore
	lassign $tmpl tmpl_type tmpl_name
	if {![dict exists $tmpstore $tmpl_name]} {
		throw {ENO TEMPLATE} "template '$tmpl_name' not found"
	}
	set template [dict get $tmpstore $tmpl_name]

	switch -exact $tmpl_type {
		"<" {
			return [section_copy $section $template]
		}
		"<<" {
			return [section_deepcopy $section $template]
		}
	}

	## unknown copy type - ignore and return original section
	return $section
}

proc eno::parse_postprocessor {data {sectiondepth 0}} {
	set result {}

	## capture non-section elements first
	set has_section false
	for {set i 0} {$i < [llength $data]} {incr i} {
		set element [lindex $data $i]
		lassign $element el_type arg1 arg2 tmpl
		if {$el_type eq "section"} {
			if {$arg2 != $sectiondepth + 1} {
				throw {ENO SECTIONDEPTH} "invalid section depth ($arg2): $arg1"
			}
			set has_section true
			break
		}
		lappend result $element
	}

	## process subsections recursively:
	##   convert sequential section parts {} {} ... to nested sections {{...}}
	while {$has_section} {
		set section {}
		set section_name $arg1
		set section_tmpl $tmpl
		set has_section false

		for {incr i} {$i < [llength $data]} {incr i} {
			set element [lindex $data $i]
			lassign $element el_type arg1 arg2 tmpl
			if {$el_type eq "section" && $arg2 == $sectiondepth + 1} {
				set has_section true
				break
			}
			lappend section $element
		}

		set section [parse_postprocessor $section [expr {$sectiondepth + 1}]]

		## process template section
		if {$section_tmpl ne {}} {
			set section [process_templates $section $section_tmpl]
		}

		## store section by name for template processing
		tmpstore_section $section_name $section

		lappend result [list section $section_name $section]
	}

	if {$sectiondepth == 0} {
		tmpstore_empty
	}

	return $result
}

## API

## get value of element
proc eno::value {element {validator {}}} {
	lassign $element el_type arg1 arg2
	if {$el_type eq "section"} {
		set element $arg1
	} else {
		set element $arg2
	}
	if {$validator ne ""} {
		return [[namespace current]::validator::$validator $element]
	}
	return $element
}

## retrieve all elements with a given name or type (or both) from current section
proc eno::filter {data args} {
	named_args {
		required false
		name {}
		type {}
		single false
		with_element true
		default {}
		validator {}
	}

	set result {}
	foreach element $data {
		lassign $element el_type arg1 arg2
		if {$type ne "" && $type ne $el_type} { continue }
		if {$name ne "" && $name ne $arg1} { continue }
		if {!$with_element} {
			set element [value $element $validator]
		}
		if {$single} {
			return $element
		}
		lappend result $element
	}
	
	## default value if not required
	if {$single && !$required} {
		set element [list field $name $default]
		if {!$with_element} {
			set element [value $default $validator]
		}
		return $element
	}

	## empty result + required -> error?
	if {$result eq {} && $required} {
		throw {ENO VALIDATE} "validation error: element $name must be present"
	}

	return $result
}

## retrieve elements by name
proc eno::elements {data name args} {
	return [filter $data name $name {*}$args]
}
## retrieve a single element by name
proc eno::element {data name args} {
	return [filter $data name $name single true {*}$args]
}

## retrieve fieldsets by name
proc eno::fieldsets {data name args} {
	return [filter $data type "fieldset" name $name {*}$args]
}

## retrieve a single fieldset by name
proc eno::fieldset {data name args} {
	return [filter $data type "fieldset" name $name single true {*}$args]
}

## retrieve fields by name
proc eno::fields {data name args} {
	return [filter $data type "field" name $name {*}$args]
}

## retrieve a single field by name
proc eno::field {data name args} {
	return [filter $data type "field" name $name single true with_element false {*}$args]
}

## retrieve lists by name
proc eno::fieldlists {data name args} {
	return [filter $data type "list" name $name {*}$args]
}

## retrieve a single list by name
proc eno::fieldlist {data name args} {
	return [filter $data type "list" name $name single true with_element false {*}$args]
}

## retrieve sections by name
proc eno::sections {data name args} {
	return [filter $data type "section" name $name {*}$args]
}

## retrieve a single section by name
proc eno::section {data name args} {
	lassign [filter $data type "section" name $name single true {*}$args] type name result
	return $result
}

## retrieve field from subsection
proc eno::sectionfield {data sectionlist name args} {
	foreach subsection $sectionlist {
		set data [section $data $subsection {*}$args]
	}
	return [field $data $name {*}$args]
}

## LOADERS and VALIDATORS

namespace eval eno::validator {
	proc boolean {value} {
		switch -exact -nocase -- $value {
			0 -
			false -
			off -
			disable -
			disabled {
				return false
			}
			1 -
			true -
			on -
			enable -
			enabled {
				return true
			}
		}
		throw {ENO VALIDATE} "validation error: $value is not boolean"
	}

	proc color {value} {
		if {![regexp -nocase -- {^#([0-9a-f]{3}|[0-9a-f]{6})$} $value]} {
			throw {ENO VALIDATE} "validation error: invalid color: $value"
		}
		return $value
	}

	proc comma_separated {value} {
		return [lmap s [split $value ","] {string trim $s}]
	}

	proc integer {value} {
		if {![string is integer -strict $value]} {
			throw {ENO VALIDATE} "validation error: invalid integer: $value"
		}
	}
}

## WRITER

proc eno::write_value {value} {
	set value [join [split $value "\n"] "\n| " ]
}
proc eno::write {data {sectiondepth 0}} {
	set result ""
	foreach element $data {
		lassign $element el_type arg1 arg2
		switch -exact -- $el_type {
			field {
				if {[regexp -lineanchor -- {^[\t ]|[\t ]$} $arg2]} {
					for {set i 2} {true} {incr i} {
						set dashes [string repeat "-" $i]
						if {[regexp -lineanchor -- "^\\s*$dashes\\s*(.*?)\\s*$" -> name] && $name eq $arg1} {
							continue
						}
						append result "$dashes $arg1\n$arg2\n$dashes $arg1\n"
						break
					}
				} else {
					set arg2 [write_value $arg2]
					append result "$arg1: $arg2\n"
				}
			}
			fieldset {
				append result "$arg1:\n"
				foreach {key value} $arg2 {
					set value [write_value $value]
					append result "$key = $value\n"
				}
			}
			list {
				append result "$arg1:\n"
				foreach item $arg2 {
					set item [write_value $item]
					append result "- $item\n"
				}
			}
			section {
				set arg1 [write_value $arg1]
				append result # [string repeat "#" $sectiondepth] " $arg1\n" [write $arg2 [expr {$sectiondepth + 1}]]
			}
			default {
				throw {ENO UNKNOWN} "unknown element $el_type"
			}
		}
	}
	return $result
}
