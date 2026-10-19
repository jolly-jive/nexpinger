# Records docs/demo/demo.gif with VHS (https://github.com/charmbracelet/vhs).
# Run from the repository root after `mix escript.build`:
#   vhs docs/demo/demo.tape

Output docs/demo/demo.gif
Set Shell "bash"
Set FontSize 14
Set Width 960
Set Height 500
Set Padding 16
Set Theme "Dracula"
Set TypingSpeed 60ms

Hide
Type "export PATH=$PWD:$PATH PS1='$ ' && cd docs/demo && clear"
Enter
Show

Type "nexpinger hosts.yml"
Sleep 400ms
Enter
Sleep 7s
Tab
Sleep 6s
Tab
Sleep 3s
Type "q"
Sleep 1s
