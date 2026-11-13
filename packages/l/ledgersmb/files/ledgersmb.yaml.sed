# LedgerSMB's sample configuration without the LaTeX output formats (PDF and
# PostScript through LaTeX): the tree has no TeX, and the Perl modules for
# them are not built. Deletes each "- $class: ...Plugin::LaTeX" entry with
# its "format:" line, and the comment line above it.
/^ *# PDF output based on LaTeX input$/d
/^ *# PostScript output based on LaTeX input$/d
/^ *- \$class: LedgerSMB::Template::Plugin::LaTeX$/{
N
d
}
