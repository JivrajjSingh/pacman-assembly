# ****************************************************************************
# * Program:     Pac-Man (endless rounds, colours, saved top scores)         *
# * Description: Pac-Man moves with W/A/S/D and eats dots while two ghosts   *
# *              hunt him: a greedy ghost that heads for him by Manhattan    *
# *              distance and a random ghost. Touching a ghost costs a life. *
# *              Clearing the maze starts a new round in which the ghosts    *
# *              are faster. The game ends when the lives run out or on Q.   *
# *              The top scores are kept in a file and shown from the menu.  *
# * Assumption:  the maze is surrounded by walls and contains exactly one    *
# *              'P' (the start position), so no bounds checks are needed.   *
# ****************************************************************************

# --- Maze geometry -----------------------------------------------------------
.equ    MAZE_WIDTH,    58                # Characters per maze row
.equ    MAZE_HEIGHT,   17                # Number of maze rows
.equ    MAZE_CELLS,    MAZE_WIDTH * MAZE_HEIGHT
.equ    ROW_BYTES,     MAZE_WIDTH + 1       # One screen row plus its newline
.equ    HEADER_BYTES,  3                    # "ESC [ H" moves the cursor home
.equ    HUD_MAX,       128                  # Room for the score line
.equ    SPRITE_SLACK,  64                   # Extra room: sprites are longer than 1 byte
.equ    SCREEN_BYTES,  HEADER_BYTES + ROW_BYTES * MAZE_HEIGHT + HUD_MAX + SPRITE_SLACK

# --- Characters --------------------------------------------------------------
.equ    CH_SPACE,      32
.equ    CH_DOT,        46
.equ    CH_START,      80                   # 'P' in the maze data
.equ    CH_NEWLINE,    10
.equ    CH_ESC,        27
.equ    CH_LBRACKET,   91
.equ    CH_H,          72

# --- Keys --------------------------------------------------------------------
.equ    KEY_CTRL_C,    3
.equ    KEY_SPACE,     32
.equ    KEY_W,         119
.equ    KEY_A,         97
.equ    KEY_S,         115
.equ    KEY_D,         100
.equ    KEY_Q,         113
.equ    KEY_P,         112
.equ    KEY_H,         104

# --- Game settings and states ------------------------------------------------
.equ    DOT_SCORE,     10                   # Points per dot
.equ    START_LIVES,   3
.equ    TICK_NSEC,     120000000            # Length of one game tick
.equ    STATE_PLAYING, 0
.equ    STATE_GAME_OVER, 1

# Ghost speed in percent of Pac-Man's speed (100 = one ghost move per tick).
# It goes up by GHOST_SPEED_STEP every round, until GHOST_SPEED_MAX.
.equ    GHOST_SPEED_START, 60
.equ    GHOST_SPEED_STEP,  10
.equ    GHOST_SPEED_MAX,   150
.equ    GHOST_SPEED_UNIT,  100

# --- Top scores --------------------------------------------------------------
.equ    SCORE_COUNT,   5
.equ    SCORES_BYTES,  SCORE_COUNT * 8
.equ    LAST_SCORE_OFF, SCORES_BYTES - 8
.equ    LINE_MAX,      100                  # Room for one line of the score table

# --- Ghosts ------------------------------------------------------------------
.equ    GHOST_COUNT,   2
.equ    TYPE_GREEDY,   0
.equ    TYPE_RANDOM,   1
# Ghost record layout (one record = 12 quadwords)
.equ    G_X,           0                    # current position
.equ    G_Y,           8
.equ    G_DX,          16                   # direction of the last move
.equ    G_DY,          24
.equ    G_TYPE,        32                   # TYPE_GREEDY or TYPE_RANDOM
.equ    G_TIMER,       40                   # ghost moves to wait before leaving
.equ    G_FREE,        48                   # 1 once the ghost has left the house
.equ    G_START_X,     56                   # where the ghost respawns
.equ    G_START_Y,     64
.equ    G_DELAY,       72                   # value G_TIMER is reset to
.equ    G_STR,         80                   # address of the string used to draw the ghost
.equ    G_SIZE,        96
# Ghost house (fixed part of this maze): ghosts leave through the door, head
# for the exit cell above it and may not walk back in afterwards.
.equ    EXIT_X,        36
.equ    EXIT_Y,        4
.equ    DOOR_Y,        5
.equ    DOOR_X0,       35
.equ    DOOR_X1,       36

# --- Linux x86-64 system calls and terminal constants -------------------------
.equ    SYS_READ,      0
.equ    SYS_WRITE,     1
.equ    SYS_OPEN,      2
.equ    SYS_CLOSE,     3
.equ    SYS_IOCTL,     16
.equ    SYS_NANOSLEEP, 35
.equ    STDIN,         0
.equ    STDOUT,        1
.equ    O_RDONLY,      0
.equ    O_WRITE_NEW,   01101                # O_WRONLY | O_CREAT | O_TRUNC (octal)
.equ    FILE_MODE,     0644                 # rw-r--r-- (octal)
.equ    TCGETS,        0x5401               # ioctl: read terminal settings
.equ    TCSETS,        0x5402               # ioctl: write terminal settings
.equ    LFLAG_OFFSET,  12                   # c_lflag inside the kernel termios
.equ    VTIME_OFFSET,  22                   # c_cc[VTIME]
.equ    VMIN_OFFSET,   23                   # c_cc[VMIN]
.equ    LFLAG_CLEAR,   0xB                  # ISIG (1) | ICANON (2) | ECHO (8)

.data
# The pristine maze. Every round starts from a fresh copy (see load_maze).
maze_orig:
.ascii "----------------------------------------------------------"
.ascii "|........................................................|"
.ascii "|.|||.|||||||||.|||||||||||||||.|||||||| |||.|||||.|||||.|"
.ascii "|.|||.|||||||||.|||||||||||||||.|||||||| |||.|||||.|||||.|"
.ascii "|.....|||||||||................          |||.............|"
.ascii "|||||.|||.......|||||||.||||||| |||  ||| |||.|||||||.|||||"
.ascii "|| ||.|||.|||||.|||||||.||||||| |      | |||.||   ||.|| ||"
.ascii "|||||.|||.|||||.||   ||.||   || |      | |||.||   ||.|||||"
.ascii "|    .|||...|||.||   ||.||   || |      | |||.|||||||.    |"
.ascii "|||||.|||||||||.||   ||.||   || |||||||| |||.|||.....|||||"
.ascii "|| ||.|||||||||.|||||||.|||||||          |||.|||||||.|| ||"
.ascii "|||||.|||||||||.|||||||.||||||| |||||||| |||.|||||||.|||||"
.ascii "|...............................|||||||| ................|"
.ascii "|.||||.||||||||||.||.||||||||||....||....|||||||||.|||||.|"
.ascii "|.||||.||||||||||.||.||||||||||.||.||.||.|||||||||.|||||.|"
.ascii "|.................||............||..P.||.................|"
.ascii "----------------------------------------------------------"


# Game state (all 64-bit so they can be used directly in address arithmetic)
state:          .quad STATE_PLAYING
player_x:       .quad 0
player_y:       .quad 0
start_x:        .quad 0                     # where Pac-Man respawns
start_y:        .quad 0
dir_x:          .quad 0                     # direction Pac-Man is moving in
dir_y:          .quad 0
want_x:         .quad 0                     # direction the player asked for
want_y:         .quad 0
score:          .quad 0
lives:          .quad START_LIVES
level:          .quad 1                     # current round
dots_left:      .quad 0
quit_flag:      .quad 0
esc_skip:       .quad 0                     # bytes of an escape sequence to ignore
ghost_speed:    .quad GHOST_SPEED_START     # ghost moves per 100 ticks
ghost_acc:      .quad 0                     # accumulates ghost_speed every tick
rng_state:      .quad 88172645463325252     # random number generator state

# Ghost table: x, y, dx, dy, type, timer, free, start x, start y, delay, string, padding
ghosts:
        .quad 38, 6, 0, 0, TYPE_GREEDY, 30, 0, 38, 6, 30, ghost_magenta, 0
        .quad 38, 8, 0, 0, TYPE_RANDOM, 15, 0, 38, 8, 15, ghost_yellow, 0

# Direction table, in tie-break order: up, left, down, right (dx, dy pairs)
dir_table:      .quad 0, -1,  -1, 0,  0, 1,  1, 0

# Sprites: colour code, UTF-8 character, colour reset.
# Pac-Man is U+15E7 (E1 97 A7), the ghosts are U+14E3 (E1 93 A3); the bytes are
# written as octal escapes. Each sprite is a single character wide on screen.
player_str:     .asciz "\033[1;33m\341\227\247\033[0m"      # yellow Pac-Man
ghost_magenta:  .asciz "\033[1;35m\341\223\243\033[0m"      # magenta ghost
ghost_yellow:   .asciz "\033[1;33m\341\223\243\033[0m"      # yellow ghost

# Strings and constants
init_seq:       .ascii "\033[2J\033[?25l"   # clear the screen, hide the cursor
.equ    INIT_LEN, . - init_seq
menu_seq:       .ascii "\033[2J\033[H\033[?25l\033[1;33m   P A C - M A N\033[0m\n\n   [P] Play\n   [H] High scores\n   [Q] Quit\n\n   In game: [W][A][S][D] move, [Q] ends the game\n"
.equ    MENU_LEN, . - menu_seq
exit_seq:       .ascii "\033[?25h\n"        # show the cursor again
.equ    EXIT_LEN, . - exit_seq
hud_fmt:        .asciz "Score: %ld  Top: %ld  Lives: %ld  Level: %ld  Dots left: %ld  [Q] end game\033[K"
scores_head:    .asciz "\033[2J\033[H\033[1;33m=== TOP SCORES ===\033[0m\n\n"
over_fmt:       .asciz "Game over!  Score: %ld   Level: %ld\n\n"
row_fmt:        .asciz "   %ld.   %8ld\n"
scores_foot:    .asciz "\nPress [SPACE] to continue\n"
msg_bye:        .asciz "Thanks for playing!\n"
score_file:     .asciz "pacman_scores.dat"
tick_spec:      .quad 0, TICK_NSEC          # struct timespec { seconds, nanoseconds }

.bss
maze:           .skip MAZE_CELLS            # working copy of the maze
scores:         .skip SCORES_BYTES          # top scores, highest first
orig_termios:   .skip 64                    # terminal settings to restore on exit
raw_termios:    .skip 64                    # modified copy used while playing
key_buf:        .skip 8                     # one byte read from the keyboard
screen:         .skip SCREEN_BYTES          # frame buffer, written in one call

.text
.global main

# ****************************************************************************
# * Subroutine: main                                                         *
# * Description: Loads the saved top scores, switches the terminal to raw    *
# *              mode and runs the menu: play, show the high scores or quit. *
# * Parameters:  none                                                        *
# * Returns:     RAX = 0 (exit status)                                       *
# ****************************************************************************
main:
        pushq   %rbp                        # prologue
        movq    %rsp, %rbp

        call    load_scores                 # top scores from the file (if any)
        call    term_raw                    # unbuffered, non-echoing keyboard

menu_loop:
        movq    $SYS_WRITE, %rax            # write(STDOUT, menu_seq, MENU_LEN)
        movq    $STDOUT, %rdi
        leaq    menu_seq(%rip), %rsi
        movq    $MENU_LEN, %rdx
        syscall
menu_wait:
        call    wait_key                    # RAX = the key that was pressed
        cmpq    $KEY_P, %rax
        je      menu_play
        cmpq    $KEY_H, %rax
        je      menu_scores
        cmpq    $KEY_Q, %rax
        je      menu_quit
        jmp     menu_wait                   # any other key is ignored

menu_play:
        call    play_game
        jmp     menu_loop
menu_scores:
        movq    $0, %rdi                    # 0: no "game over" line
        call    show_scores
        jmp     menu_loop

menu_quit:
        call    term_restore                # give the terminal back first
        movq    $0, %rax                    # no vector registers used by printf
        leaq    msg_bye(%rip), %rdi
        call    printf

        movq    $0, %rax                    # exit status 0
        movq    %rbp, %rsp                  # epilogue
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: play_game                                                    *
# * Description: Plays one game: input, update, draw, wait, until the lives  *
# *              run out or the player presses Q. Then the score is added to *
# *              the top scores and the table is shown.                      *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
play_game:
        pushq   %rbp
        movq    %rsp, %rbp

        call    new_game                    # fresh maze, score and lives
play_loop:
        call    input_poll                  # read pending key presses
        call    update                      # move Pac-Man and the ghosts
        call    render                      # draw the frame
        call    sleep_tick                  # wait for the next tick

        cmpq    $0, quit_flag(%rip)         # did the player press Q?
        jne     play_end
        cmpq    $STATE_PLAYING, state(%rip) # did the game end by itself?
        je      play_loop

play_end:
        call    add_score                   # enter the score in the table
        movq    $1, %rdi                    # 1: show the "game over" line
        call    show_scores

        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: wait_key                                                     *
# * Description: Waits (polling, with a short sleep) until a key is pressed.  *
# *              Capital letters are folded to lower case and Ctrl-C is      *
# *              reported as 'q'.                                            *
# * Parameters:  none                                                        *
# * Returns:     RAX = the key                                               *
# ****************************************************************************
wait_key:
        pushq   %rbp
        movq    %rsp, %rbp

wait_poll:
        movq    $SYS_READ, %rax             # read(STDIN, key_buf, 1)
        movq    $STDIN, %rdi
        leaq    key_buf(%rip), %rsi
        movq    $1, %rdx
        syscall
        cmpq    $1, %rax                    # 0 means no key is waiting
        je      wait_got
        call    sleep_tick
        jmp     wait_poll
wait_got:
        movzbq  key_buf(%rip), %rax
        cmpq    $KEY_CTRL_C, %rax
        jne     wait_fold
        movq    $KEY_Q, %rax
        jmp     wait_done
wait_fold:
        orq     $0x20, %rax                 # fold capital letters to lower case
wait_done:
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: load_scores                                                  *
# * Description: Reads the top scores from the score file into the table.    *
# *              If the file does not exist, the table stays all zeros.      *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
load_scores:
        pushq   %rbp
        movq    %rsp, %rbp
        subq    $16, %rsp                   # room for the file descriptor

        movq    $SYS_OPEN, %rax             # open(score_file, O_RDONLY)
        leaq    score_file(%rip), %rdi
        movq    $O_RDONLY, %rsi
        movq    $0, %rdx
        syscall
        testq   %rax, %rax
        js      load_done                   # negative: no file yet
        movq    %rax, -8(%rbp)              # keep the file descriptor

        movq    $SYS_READ, %rax             # read(fd, scores, SCORES_BYTES)
        movq    -8(%rbp), %rdi
        leaq    scores(%rip), %rsi
        movq    $SCORES_BYTES, %rdx
        syscall

        movq    $SYS_CLOSE, %rax            # close(fd)
        movq    -8(%rbp), %rdi
        syscall
load_done:
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: save_scores                                                  *
# * Description: Writes the whole score table to the score file, replacing   *
# *              the old contents (the file is created if needed).           *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
save_scores:
        pushq   %rbp
        movq    %rsp, %rbp
        subq    $16, %rsp                   # room for the file descriptor

        movq    $SYS_OPEN, %rax             # open(score_file, write | create | truncate, 0644)
        leaq    score_file(%rip), %rdi
        movq    $O_WRITE_NEW, %rsi
        movq    $FILE_MODE, %rdx
        syscall
        testq   %rax, %rax
        js      save_done                   # cannot write: the scores stay in memory
        movq    %rax, -8(%rbp)

        movq    $SYS_WRITE, %rax            # write(fd, scores, SCORES_BYTES)
        movq    -8(%rbp), %rdi
        leaq    scores(%rip), %rsi
        movq    $SCORES_BYTES, %rdx
        syscall

        movq    $SYS_CLOSE, %rax            # close(fd)
        movq    -8(%rbp), %rdi
        syscall
save_done:
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: add_score                                                    *
# * Description: If the current score beats the lowest entry of the table,   *
# *              it replaces that entry and is moved up to its place, so the *
# *              table stays sorted (highest first). Then the file is saved. *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
add_score:
        pushq   %rbp
        movq    %rsp, %rbp

        leaq    scores(%rip), %rsi          # RSI = the table
        movq    score(%rip), %rax           # RAX = the new score
        cmpq    LAST_SCORE_OFF(%rsi), %rax
        jle     add_done                    # not better than the last entry
        movq    %rax, LAST_SCORE_OFF(%rsi)  # replace the last entry ...
        movq    $SCORE_COUNT - 1, %rcx      # RCX = index of the entry that moves up
add_bubble:
        testq   %rcx, %rcx
        jz      add_save                    # reached the top
        movq    (%rsi,%rcx,8), %rax         # this entry ...
        movq    -8(%rsi,%rcx,8), %rdx       # ... and the one above it
        cmpq    %rdx, %rax
        jle     add_save                    # already in the right place
        movq    %rdx, (%rsi,%rcx,8)         # swap them
        movq    %rax, -8(%rsi,%rcx,8)
        decq    %rcx
        jmp     add_bubble
add_save:
        call    save_scores
add_done:
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: show_scores                                                  *
# * Description: Draws the top scores table (and, after a game, the final    *
# *              score and level) and waits for SPACE (or Q).                *
# * Parameters:  RDI = 1 to show the "game over" line, 0 to leave it out     *
# * Returns:     nothing                                                     *
# ****************************************************************************
show_scores:
        pushq   %rbp
        movq    %rsp, %rbp
        subq    $32, %rsp
        movq    %rbx, -8(%rbp)              # RBX = write position in the buffer
        movq    %r12, -16(%rbp)             # R12 = table index
        movq    %r13, -24(%rbp)             # R13 = the "game over" flag

        movq    %rdi, %r13
        leaq    screen(%rip), %rbx
        movq    %rbx, %rdi                  # clear the screen and print the title
        leaq    scores_head(%rip), %rsi
        call    emit_str
        movq    %rdi, %rbx

        testq   %r13, %r13
        jz      scores_rows
        movq    %rbx, %rdi                  # snprintf(buf, LINE_MAX, over_fmt, score, level)
        movq    $LINE_MAX, %rsi
        leaq    over_fmt(%rip), %rdx
        movq    score(%rip), %rcx
        movq    level(%rip), %r8
        movq    $0, %rax
        call    snprintf
        addq    %rax, %rbx

scores_rows:
        movq    $0, %r12
scores_loop:
        cmpq    $SCORE_COUNT, %r12
        jge     scores_foot_line
        movq    %rbx, %rdi                  # snprintf(buf, LINE_MAX, row_fmt, rank, score)
        movq    $LINE_MAX, %rsi
        leaq    row_fmt(%rip), %rdx
        leaq    1(%r12), %rcx               # rank = index + 1
        leaq    scores(%rip), %rax
        movq    (%rax,%r12,8), %r8
        movq    $0, %rax
        call    snprintf
        addq    %rax, %rbx
        incq    %r12
        jmp     scores_loop

scores_foot_line:
        movq    %rbx, %rdi
        leaq    scores_foot(%rip), %rsi
        call    emit_str
        movq    %rdi, %rbx

        leaq    screen(%rip), %rsi          # write(STDOUT, screen, end - screen)
        movq    %rbx, %rdx
        subq    %rsi, %rdx
        movq    $SYS_WRITE, %rax
        movq    $STDOUT, %rdi
        syscall

scores_wait:
        call    wait_key
        cmpq    $KEY_SPACE, %rax
        je      scores_done
        cmpq    $KEY_Q, %rax
        jne     scores_wait

scores_done:
        movq    -8(%rbp), %rbx
        movq    -16(%rbp), %r12
        movq    -24(%rbp), %r13
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: term_raw                                                     *
# * Description: Saves the terminal settings and switches the terminal to    *
# *              non-canonical, non-echoing mode where read() returns        *
# *              immediately, with or without a key press.                   *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
term_raw:
        pushq   %rbp
        movq    %rsp, %rbp

        movq    $SYS_IOCTL, %rax            # ioctl(STDIN, TCGETS, &orig_termios)
        movq    $STDIN, %rdi
        movq    $TCGETS, %rsi
        leaq    orig_termios(%rip), %rdx
        syscall

        leaq    orig_termios(%rip), %rsi    # copy the settings (8 quadwords)
        leaq    raw_termios(%rip), %rdi
        movq    $8, %rcx
        rep movsq

        andl    $~LFLAG_CLEAR, raw_termios+LFLAG_OFFSET(%rip)   # no line mode, echo or signals
        movb    $0, raw_termios+VTIME_OFFSET(%rip)              # no read timeout
        movb    $0, raw_termios+VMIN_OFFSET(%rip)               # read may return 0 bytes

        movq    $SYS_IOCTL, %rax            # ioctl(STDIN, TCSETS, &raw_termios)
        movq    $STDIN, %rdi
        movq    $TCSETS, %rsi
        leaq    raw_termios(%rip), %rdx
        syscall

        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: term_restore                                                 *
# * Description: Restores the saved terminal settings and shows the cursor.  *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
term_restore:
        pushq   %rbp
        movq    %rsp, %rbp

        movq    $SYS_IOCTL, %rax            # ioctl(STDIN, TCSETS, &orig_termios)
        movq    $STDIN, %rdi
        movq    $TCSETS, %rsi
        leaq    orig_termios(%rip), %rdx
        syscall

        movq    $SYS_WRITE, %rax            # write(STDOUT, exit_seq, EXIT_LEN)
        movq    $STDOUT, %rdi
        leaq    exit_seq(%rip), %rsi
        movq    $EXIT_LEN, %rdx
        syscall

        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: load_maze                                                    *
# * Description: Copies the pristine maze into the working maze, counts the  *
# *              dots and records where the 'P' is (then turns that cell     *
# *              into an empty one).                                         *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
load_maze:
        pushq   %rbp
        movq    %rsp, %rbp

        movq    $0, dots_left(%rip)
        leaq    maze_orig(%rip), %rsi       # copy the maze byte by byte
        leaq    maze(%rip), %rdi
        movq    $MAZE_CELLS, %rcx
        rep movsb

        leaq    maze(%rip), %rsi            # RSI = start of the working maze
        movq    $0, %rcx                    # RCX = index of the current cell

load_scan:
        cmpq    $MAZE_CELLS, %rcx           # all cells scanned?
        jge     load_scan_done
        movzbq  (%rsi,%rcx), %rax           # RAX = the cell's character

        cmpq    $CH_DOT, %rax
        jne     load_not_dot
        incq    dots_left(%rip)             # one more dot to eat
        jmp     load_next

load_not_dot:
        cmpq    $CH_START, %rax
        jne     load_next
        movb    $CH_SPACE, (%rsi,%rcx)      # the start cell holds no dot
        movq    %rcx, %rax                  # index = y * WIDTH + x, so divide
        movq    $0, %rdx
        movq    $MAZE_WIDTH, %rdi
        divq    %rdi                        # RAX = y (quotient), RDX = x (remainder)
        movq    %rax, player_y(%rip)
        movq    %rdx, player_x(%rip)
        movq    %rax, start_y(%rip)         # remember it for respawning
        movq    %rdx, start_x(%rip)

load_next:
        incq    %rcx
        jmp     load_scan

load_scan_done:
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: new_game                                                     *
# * Description: Seeds the random number generator, resets score, lives,     *
# *              level and ghost speed, loads a fresh maze, puts everyone on *
# *              their start cell, then clears the screen and hides the      *
# *              cursor.                                                     *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
new_game:
        pushq   %rbp
        movq    %rsp, %rbp

        rdtsc                               # time stamp counter -> EDX:EAX
        shlq    $32, %rdx
        orq     %rdx, %rax
        movq    %rax, rng_state(%rip)       # a different seed on every game

        movq    $0, score(%rip)
        movq    $START_LIVES, lives(%rip)
        movq    $1, level(%rip)
        movq    $GHOST_SPEED_START, ghost_speed(%rip)
        movq    $0, ghost_acc(%rip)
        movq    $0, quit_flag(%rip)
        movq    $0, esc_skip(%rip)
        movq    $STATE_PLAYING, state(%rip)

        call    load_maze
        call    reset_positions

        movq    $SYS_WRITE, %rax            # write(STDOUT, init_seq, INIT_LEN)
        movq    $STDOUT, %rdi
        leaq    init_seq(%rip), %rsi
        movq    $INIT_LEN, %rdx
        syscall

        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: next_round                                                   *
# * Description: Called when the last dot is eaten. Raises the level and the *
# *              ghost speed (up to GHOST_SPEED_MAX), refills the maze and   *
# *              sends everyone back to their start cell. Score and lives    *
# *              are kept.                                                   *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
next_round:
        pushq   %rbp
        movq    %rsp, %rbp

        incq    level(%rip)
        movq    ghost_speed(%rip), %rax
        addq    $GHOST_SPEED_STEP, %rax
        cmpq    $GHOST_SPEED_MAX, %rax
        jle     round_speed_ok
        movq    $GHOST_SPEED_MAX, %rax      # never faster than the maximum
round_speed_ok:
        movq    %rax, ghost_speed(%rip)

        call    load_maze                   # all dots are back
        call    reset_positions

        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: input_poll                                                   *
# * Description: Reads every key waiting in the keyboard buffer without      *
# *              blocking and updates the wanted direction (W/A/S/D) or the  *
# *              quit flag (Q or Ctrl-C). Arrow keys send three bytes        *
# *              (ESC [ letter); those are skipped so they cannot be         *
# *              mistaken for W/A/S/D.                                       *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
input_poll:
        pushq   %rbp
        movq    %rsp, %rbp

poll_next_byte:
        movq    $SYS_READ, %rax             # read(STDIN, key_buf, 1)
        movq    $STDIN, %rdi
        leaq    key_buf(%rip), %rsi
        movq    $1, %rdx
        syscall
        cmpq    $1, %rax                    # 0 means no key is waiting
        jne     poll_done
        movzbq  key_buf(%rip), %rax         # RAX = the key that was read

        cmpq    $0, esc_skip(%rip)          # inside an escape sequence?
        je      poll_not_skipping
        decq    esc_skip(%rip)              # ignore this byte
        jmp     poll_next_byte

poll_not_skipping:
        cmpq    $CH_ESC, %rax
        jne     poll_not_escape
        movq    $2, esc_skip(%rip)          # ignore the next two bytes
        jmp     poll_next_byte

poll_not_escape:
        cmpq    $KEY_CTRL_C, %rax           # raw mode delivers Ctrl-C as a byte
        je      poll_quit
        orq     $0x20, %rax                 # fold capital letters to lower case

        cmpq    $KEY_W, %rax
        je      poll_up
        cmpq    $KEY_A, %rax
        je      poll_left
        cmpq    $KEY_S, %rax
        je      poll_down
        cmpq    $KEY_D, %rax
        je      poll_right
        cmpq    $KEY_Q, %rax
        je      poll_quit
        jmp     poll_next_byte              # any other key is ignored

poll_up:
        movq    $0, want_x(%rip)
        movq    $-1, want_y(%rip)
        jmp     poll_next_byte
poll_left:
        movq    $-1, want_x(%rip)
        movq    $0, want_y(%rip)
        jmp     poll_next_byte
poll_down:
        movq    $0, want_x(%rip)
        movq    $1, want_y(%rip)
        jmp     poll_next_byte
poll_right:
        movq    $1, want_x(%rip)
        movq    $0, want_y(%rip)
        jmp     poll_next_byte
poll_quit:
        movq    $1, quit_flag(%rip)

poll_done:
        movq    $0, esc_skip(%rip)          # an escape sequence never spans ticks
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: cell_addr                                                    *
# * Description: Computes the address of a maze cell.                        *
# * Parameters:  RDI = x, RSI = y                                            *
# * Returns:     RAX = address of maze[y * MAZE_WIDTH + x]                   *
# * Clobbers:    RDX (caller-saved)                                          *
# ****************************************************************************
cell_addr:
        pushq   %rbp
        movq    %rsp, %rbp

        imulq   $MAZE_WIDTH, %rsi, %rax     # RAX = y * MAZE_WIDTH
        addq    %rdi, %rax                  # ... + x
        leaq    maze(%rip), %rdx
        addq    %rdx, %rax                  # ... + start of the maze

        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: is_open                                                      *
# * Description: Tells whether a cell can be walked on (dot or empty).       *
# * Parameters:  RDI = x, RSI = y                                            *
# * Returns:     RAX = 1 if the cell is walkable, 0 if it is a wall          *
# ****************************************************************************
is_open:
        pushq   %rbp
        movq    %rsp, %rbp

        call    cell_addr                   # RAX = address of the cell
        movzbq  (%rax), %rax                # RAX = the cell's character
        cmpq    $CH_SPACE, %rax
        je      is_open_yes
        cmpq    $CH_DOT, %rax
        je      is_open_yes
        movq    $0, %rax                    # anything else is a wall
        jmp     is_open_done
is_open_yes:
        movq    $1, %rax
is_open_done:
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: next_random                                                  *
# * Description: Linear congruential generator (Knuth's MMIX constants).     *
# *              The low bits of such a generator are weak, so only the      *
# *              upper 31 bits of the state are returned.                    *
# * Parameters:  none                                                        *
# * Returns:     RAX = pseudo-random number in 0 .. 2^31 - 1                 *
# * Clobbers:    RCX (caller-saved)                                          *
# ****************************************************************************
next_random:
        pushq   %rbp
        movq    %rsp, %rbp

        movq    $6364136223846793005, %rax  # state = state * a + c  (mod 2^64)
        imulq   rng_state(%rip), %rax
        movq    $1442695040888963407, %rcx
        addq    %rcx, %rax
        movq    %rax, rng_state(%rip)
        shrq    $33, %rax                   # keep the upper 31 bits

        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: update                                                       *
# * Description: Advances the game by one tick. Pac-Man moves one cell: the  *
# *              wanted direction is tried first; if a wall is in the way he *
# *              keeps going in his current direction, and stands still if   *
# *              that is blocked too. Eating a dot scores points; eating the *
# *              last one starts the next, faster round. Then the ghosts move *
# *              and collisions are handled.                                 *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
update:
        pushq   %rbp
        movq    %rsp, %rbp
        subq    $16, %rsp                   # room for two callee-saved registers
        movq    %rbx, -8(%rbp)              # RBX = candidate x
        movq    %r12, -16(%rbp)             # R12 = candidate y

        movq    player_x(%rip), %rbx        # candidate = position + wanted direction
        addq    want_x(%rip), %rbx
        movq    player_y(%rip), %r12
        addq    want_y(%rip), %r12
        movq    %rbx, %rdi
        movq    %r12, %rsi
        call    is_open
        testq   %rax, %rax
        jz      update_keep_going           # wall: try the current direction

        movq    want_x(%rip), %rax          # the turn is possible: commit to it
        movq    %rax, dir_x(%rip)
        movq    want_y(%rip), %rax
        movq    %rax, dir_y(%rip)
        jmp     update_move

update_keep_going:
        movq    player_x(%rip), %rbx        # candidate = position + current direction
        addq    dir_x(%rip), %rbx
        movq    player_y(%rip), %r12
        addq    dir_y(%rip), %r12
        movq    %rbx, %rdi
        movq    %r12, %rsi
        call    is_open
        testq   %rax, %rax
        jz      update_after_move           # blocked as well: stand still

update_move:
        movq    %rbx, player_x(%rip)        # step onto the candidate cell
        movq    %r12, player_y(%rip)
        movq    %rbx, %rdi
        movq    %r12, %rsi
        call    cell_addr                   # RAX = address of the new cell
        cmpb    $CH_DOT, (%rax)
        jne     update_after_move           # nothing to eat here
        movb    $CH_SPACE, (%rax)           # eat the dot
        addq    $DOT_SCORE, score(%rip)
        decq    dots_left(%rip)
        jnz     update_after_move           # dots remain
        call    next_round                  # that was the last dot: next round
        jmp     update_done

update_after_move:
        call    check_collision             # did Pac-Man walk into a ghost?
        testq   %rax, %rax
        jz      update_ghosts
        call    lose_life
        jmp     update_done

update_ghosts:
        call    ghosts_update               # now the ghosts get their turn

update_done:
        movq    -8(%rbp), %rbx              # epilogue: restore callee-saved registers
        movq    -16(%rbp), %r12
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: ghosts_update                                                *
# * Description: Adds the ghost speed to an accumulator every tick. Each     *
# *              time the accumulator reaches 100, all ghosts move one cell, *
# *              so a speed of 50 means one move every 2nd tick and 150 means *
# *              three moves every two ticks. After each ghost move it checks *
# *              whether the ghost caught Pac-Man.                           *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
ghosts_update:
        pushq   %rbp
        movq    %rsp, %rbp
        subq    $16, %rsp
        movq    %rbx, -8(%rbp)              # RBX = pointer to the current ghost
        movq    %r12, -16(%rbp)             # R12 = ghosts left to move

        movq    ghost_speed(%rip), %rax
        addq    %rax, ghost_acc(%rip)
ghosts_round:
        cmpq    $GHOST_SPEED_UNIT, ghost_acc(%rip)
        jl      ghosts_done                 # not enough accumulated: ghosts rest
        subq    $GHOST_SPEED_UNIT, ghost_acc(%rip)

        leaq    ghosts(%rip), %rbx
        movq    $GHOST_COUNT, %r12
ghosts_loop:
        movq    %rbx, %rdi                  # argument: pointer to the ghost
        call    ghost_move
        call    check_collision
        testq   %rax, %rax
        jz      ghosts_next
        call    lose_life                   # caught: the round restarts
        jmp     ghosts_done
ghosts_next:
        addq    $G_SIZE, %rbx
        decq    %r12
        jnz     ghosts_loop
        jmp     ghosts_round                # maybe another move this tick

ghosts_done:
        movq    -8(%rbp), %rbx
        movq    -16(%rbp), %r12
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: ghost_can_enter                                              *
# * Description: Tells whether a ghost may step onto a cell: it must be      *
# *              walkable, and a ghost that already left the house may not   *
# *              walk back through the door.                                 *
# * Parameters:  RDI = x, RSI = y, RDX = 1 if the ghost has left the house   *
# * Returns:     RAX = 1 if the ghost may enter, 0 otherwise                 *
# ****************************************************************************
ghost_can_enter:
        pushq   %rbp
        movq    %rsp, %rbp
        subq    $32, %rsp
        movq    %rdi, -8(%rbp)              # keep the arguments across the call
        movq    %rsi, -16(%rbp)
        movq    %rdx, -24(%rbp)

        call    is_open
        testq   %rax, %rax
        jz      can_enter_done              # a wall: RAX is already 0

        cmpq    $0, -24(%rbp)               # still inside the house: door is fine
        je      can_enter_yes
        cmpq    $DOOR_Y, -16(%rbp)          # not the door row: fine
        jne     can_enter_yes
        movq    -8(%rbp), %rcx
        cmpq    $DOOR_X0, %rcx              # left of the door: fine
        jl      can_enter_yes
        cmpq    $DOOR_X1, %rcx              # right of the door: fine
        jg      can_enter_yes
        movq    $0, %rax                    # it is the door: not allowed again
        jmp     can_enter_done
can_enter_yes:
        movq    $1, %rax
can_enter_done:
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: ghost_move                                                   *
# * Description: Moves one ghost by one cell.                                *
# *   1. A ghost first waits for its release timer to run out.               *
# *   2. It collects the directions it may take, never turning straight      *
# *      back unless it is in a dead end (like the original game).           *
# *   3. A greedy ghost takes the direction whose next cell has the smallest *
# *      Manhattan distance |dx| + |dy| to its target, preferring up, left,  *
# *      down, right on ties. There is no pathfinding. The target is Pac-Man *
# *      or, while the ghost is still in the house, the cell outside the     *
# *      door. A random ghost picks one of the directions at random, but     *
# *      also heads for the door while it is still inside the house.         *
# * Parameters:  RDI = pointer to the ghost record                           *
# * Returns:     nothing                                                     *
# ****************************************************************************
ghost_move:
        pushq   %rbp
        movq    %rsp, %rbp
        subq    $96, %rsp                   # saved registers and local variables
        movq    %rbx, -8(%rbp)              # RBX = pointer to the ghost
        movq    %r12, -16(%rbp)             # R12 = direction index
        movq    %r13, -24(%rbp)             # R13 = number of candidate directions
        movq    %r14, -32(%rbp)             # R14 = dx, later the target x
        movq    %r15, -40(%rbp)             # R15 = dy, later the target y
        # -72(%rbp) .. -48(%rbp): up to four candidate direction indices
        # -80(%rbp): the direction straight back, or -1 if it is blocked

        movq    %rdi, %rbx
        movq    $-1, -80(%rbp)

        cmpq    $0, G_TIMER(%rbx)           # still waiting to be released?
        je      ghost_ready
        decq    G_TIMER(%rbx)
        jmp     ghost_done

ghost_ready:
        cmpq    $EXIT_Y, G_Y(%rbx)          # above the door row: outside the house
        jg      ghost_scan
        movq    $1, G_FREE(%rbx)

ghost_scan:
        movq    $0, %r13                    # no candidates yet
        movq    $0, %r12                    # start with direction 0 (up)
ghost_scan_loop:
        cmpq    $4, %r12
        jge     ghost_scan_done
        movq    %r12, %rax                  # RAX = &dir_table[R12] (16 bytes per entry)
        shlq    $4, %rax
        leaq    dir_table(%rip), %rcx
        addq    %rcx, %rax
        movq    (%rax), %r14                # R14 = dx
        movq    8(%rax), %r15               # R15 = dy

        movq    G_X(%rbx), %rdi             # the cell this direction leads to
        addq    %r14, %rdi
        movq    G_Y(%rbx), %rsi
        addq    %r15, %rsi
        movq    G_FREE(%rbx), %rdx
        call    ghost_can_enter
        testq   %rax, %rax
        jz      ghost_scan_next             # wall or door: not possible

        movq    G_DX(%rbx), %rax            # is this the way straight back?
        negq    %rax
        cmpq    %rax, %r14
        jne     ghost_candidate
        movq    G_DY(%rbx), %rax
        negq    %rax
        cmpq    %rax, %r15
        jne     ghost_candidate
        movq    %r12, -80(%rbp)             # remember it as a last resort
        jmp     ghost_scan_next

ghost_candidate:
        movq    %r12, -72(%rbp,%r13,8)      # candidates[count] = direction index
        incq    %r13
ghost_scan_next:
        incq    %r12
        jmp     ghost_scan_loop

ghost_scan_done:
        testq   %r13, %r13
        jnz     ghost_choose
        movq    -80(%rbp), %rax             # no candidate: dead end, turn around
        testq   %rax, %rax
        js      ghost_done                  # not even that: boxed in, stay put
        movq    %rax, -72(%rbp)
        movq    $1, %r13

ghost_choose:
        cmpq    $TYPE_RANDOM, G_TYPE(%rbx)
        jne     ghost_greedy
        cmpq    $0, G_FREE(%rbx)            # a random ghost still in the house
        je      ghost_greedy                # also heads for the door

        call    next_random                 # RAX = random number
        movq    $0, %rdx
        divq    %r13                        # RDX = RAX mod number of candidates
        movq    -72(%rbp,%rdx,8), %r12      # R12 = the chosen direction index
        jmp     ghost_apply

ghost_greedy:
        movq    $EXIT_X, %r14               # target: the cell outside the door ...
        movq    $EXIT_Y, %r15
        cmpq    $0, G_FREE(%rbx)
        je      ghost_have_target
        movq    player_x(%rip), %r14        # ... or Pac-Man once the ghost is free
        movq    player_y(%rip), %r15
ghost_have_target:
        movq    $0, %r9                     # R9 = candidate number
        movq    $1000000, %r10              # R10 = best distance so far
        movq    -72(%rbp), %r12             # R12 = best direction (first candidate)
ghost_eval_loop:
        cmpq    %r13, %r9
        jge     ghost_apply
        movq    -72(%rbp,%r9,8), %rax       # RAX = &dir_table[candidate]
        shlq    $4, %rax
        leaq    dir_table(%rip), %rcx
        addq    %rcx, %rax
        movq    G_X(%rbx), %rdi             # |new x - target x|
        addq    (%rax), %rdi
        subq    %r14, %rdi
        jns     ghost_dx_done
        negq    %rdi
ghost_dx_done:
        movq    G_Y(%rbx), %rsi             # |new y - target y|
        addq    8(%rax), %rsi
        subq    %r15, %rsi
        jns     ghost_dy_done
        negq    %rsi
ghost_dy_done:
        addq    %rsi, %rdi                  # Manhattan distance
        cmpq    %r10, %rdi
        jge     ghost_eval_next             # not better (ties keep the earlier one)
        movq    %rdi, %r10
        movq    -72(%rbp,%r9,8), %r12
ghost_eval_next:
        incq    %r9
        jmp     ghost_eval_loop

ghost_apply:
        shlq    $4, %r12                    # R12 = &dir_table[chosen direction]
        leaq    dir_table(%rip), %rax
        addq    %rax, %r12
        movq    (%r12), %rax                # remember the direction and step
        movq    %rax, G_DX(%rbx)
        addq    %rax, G_X(%rbx)
        movq    8(%r12), %rax
        movq    %rax, G_DY(%rbx)
        addq    %rax, G_Y(%rbx)

ghost_done:
        movq    -8(%rbp), %rbx              # epilogue: restore callee-saved registers
        movq    -16(%rbp), %r12
        movq    -24(%rbp), %r13
        movq    -32(%rbp), %r14
        movq    -40(%rbp), %r15
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: check_collision                                              *
# * Description: Checks whether any ghost is on Pac-Man's cell.              *
# * Parameters:  none                                                        *
# * Returns:     RAX = 1 on a collision, 0 otherwise                         *
# * Clobbers:    RCX, RSI, RDX (caller-saved)                                *
# ****************************************************************************
check_collision:
        pushq   %rbp
        movq    %rsp, %rbp

        leaq    ghosts(%rip), %rsi          # RSI = current ghost record
        movq    $GHOST_COUNT, %rcx          # RCX = ghosts left to check
collision_loop:
        movq    G_X(%rsi), %rax
        cmpq    player_x(%rip), %rax
        jne     collision_next
        movq    G_Y(%rsi), %rax
        cmpq    player_y(%rip), %rax
        jne     collision_next
        movq    $1, %rax                    # same cell: collision
        jmp     collision_done
collision_next:
        addq    $G_SIZE, %rsi
        decq    %rcx
        jnz     collision_loop
        movq    $0, %rax                    # no ghost on Pac-Man's cell
collision_done:
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: lose_life                                                    *
# * Description: Takes a life. With lives left, Pac-Man and the ghosts go    *
# *              back to their start positions; otherwise the game is over.  *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
lose_life:
        pushq   %rbp
        movq    %rsp, %rbp

        decq    lives(%rip)
        jnz     life_reset
        movq    $STATE_GAME_OVER, %rax
        movq    %rax, state(%rip)           # no lives left
        jmp     life_done
life_reset:
        call    reset_positions
life_done:
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: reset_positions                                              *
# * Description: Puts Pac-Man and all ghosts back on their start cells,      *
# *              stops their movement and restarts the ghosts' release       *
# *              timers. Dots that were eaten stay eaten.                    *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
reset_positions:
        pushq   %rbp
        movq    %rsp, %rbp

        movq    start_x(%rip), %rax         # Pac-Man back to the start
        movq    %rax, player_x(%rip)
        movq    start_y(%rip), %rax
        movq    %rax, player_y(%rip)
        movq    $0, dir_x(%rip)
        movq    $0, dir_y(%rip)
        movq    $0, want_x(%rip)
        movq    $0, want_y(%rip)

        leaq    ghosts(%rip), %rsi          # RSI = current ghost record
        movq    $GHOST_COUNT, %rcx          # RCX = ghosts left to reset
reset_loop:
        movq    G_START_X(%rsi), %rax
        movq    %rax, G_X(%rsi)
        movq    G_START_Y(%rsi), %rax
        movq    %rax, G_Y(%rsi)
        movq    $0, G_DX(%rsi)
        movq    $0, G_DY(%rsi)
        movq    $0, G_FREE(%rsi)            # back inside the house
        movq    G_DELAY(%rsi), %rax
        movq    %rax, G_TIMER(%rsi)
        addq    $G_SIZE, %rsi
        decq    %rcx
        jnz     reset_loop

        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: emit_str                                                     *
# * Description: Copies a zero-terminated string to a buffer (without the    *
# *              terminating zero).                                          *
# * Parameters:  RDI = destination, RSI = source string                      *
# * Returns:     RDI = destination position after the last copied byte       *
# * Clobbers:    RAX, RSI (caller-saved)                                     *
# ****************************************************************************
emit_str:
        pushq   %rbp
        movq    %rsp, %rbp

emit_loop:
        movb    (%rsi), %al
        testb   %al, %al
        jz      emit_done
        movb    %al, (%rdi)
        incq    %rsi
        incq    %rdi
        jmp     emit_loop
emit_done:
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: sprite_at                                                    *
# * Description: Tells which sprite (Pac-Man or a ghost) is drawn on a cell. *
# *              Pac-Man wins over the ghosts.                               *
# * Parameters:  RDI = x, RSI = y                                            *
# * Returns:     RAX = address of the sprite string, or 0 for no sprite      *
# * Clobbers:    RCX, RDX (caller-saved)                                     *
# ****************************************************************************
sprite_at:
        pushq   %rbp
        movq    %rsp, %rbp

        cmpq    player_x(%rip), %rdi
        jne     sprite_ghosts
        cmpq    player_y(%rip), %rsi
        jne     sprite_ghosts
        leaq    player_str(%rip), %rax
        jmp     sprite_done

sprite_ghosts:
        leaq    ghosts(%rip), %rdx          # RDX = current ghost record
        movq    $GHOST_COUNT, %rcx          # RCX = ghosts left to check
sprite_loop:
        cmpq    G_X(%rdx), %rdi
        jne     sprite_next
        cmpq    G_Y(%rdx), %rsi
        jne     sprite_next
        movq    G_STR(%rdx), %rax           # this ghost is on the cell
        jmp     sprite_done
sprite_next:
        addq    $G_SIZE, %rdx
        decq    %rcx
        jnz     sprite_loop
        movq    $0, %rax                    # nothing here
sprite_done:
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: render                                                       *
# * Description: Builds a full frame in the screen buffer (cursor home, the  *
# *              maze cell by cell with the coloured ghosts and Pac-Man in   *
# *              place of the maze characters, then the score line) and      *
# *              writes it to standard output with one write call.           *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
render:
        pushq   %rbp
        movq    %rsp, %rbp
        subq    $32, %rsp
        movq    %rbx, -8(%rbp)              # RBX = write position in the buffer
        movq    %r12, -16(%rbp)             # R12 = y
        movq    %r13, -24(%rbp)             # R13 = x
        movq    %r14, -32(%rbp)             # R14 = read position in the maze

        leaq    screen(%rip), %rbx
        movb    $CH_ESC, (%rbx)             # "ESC [ H": move the cursor to the top left
        movb    $CH_LBRACKET, 1(%rbx)
        movb    $CH_H, 2(%rbx)
        addq    $HEADER_BYTES, %rbx

        leaq    maze(%rip), %r14
        movq    $0, %r12
render_row:
        cmpq    $MAZE_HEIGHT, %r12
        jge     render_hud
        movq    $0, %r13
render_col:
        cmpq    $MAZE_WIDTH, %r13
        jge     render_row_end
        movq    %r13, %rdi                  # is a sprite drawn on this cell?
        movq    %r12, %rsi
        call    sprite_at
        testq   %rax, %rax
        jz      render_plain
        movq    %rbx, %rdi                  # yes: copy the sprite string
        movq    %rax, %rsi
        call    emit_str
        movq    %rdi, %rbx
        jmp     render_col_next
render_plain:
        movb    (%r14), %al                 # no: copy the maze character
        movb    %al, (%rbx)
        incq    %rbx
render_col_next:
        incq    %r14
        incq    %r13
        jmp     render_col
render_row_end:
        movb    $CH_NEWLINE, (%rbx)         # end the row
        incq    %rbx
        incq    %r12
        jmp     render_row

render_hud:
        movq    scores(%rip), %r8           # R8 = best score so far (table or current game)
        cmpq    %r8, score(%rip)
        jle     render_top_ok
        movq    score(%rip), %r8
render_top_ok:
        pushq   dots_left(%rip)             # 8th argument
        pushq   level(%rip)                 # 7th argument
        movq    %rbx, %rdi                  # snprintf(buf, HUD_MAX, hud_fmt, score, top, lives, level, dots)
        movq    $HUD_MAX, %rsi
        leaq    hud_fmt(%rip), %rdx
        movq    score(%rip), %rcx
        movq    lives(%rip), %r9
        movq    $0, %rax                    # no vector registers used
        call    snprintf                    # RAX = number of characters written
        addq    $16, %rsp                   # remove the two stack arguments

        leaq    screen(%rip), %rsi          # bytes to write = (score line end) - buffer start
        addq    %rbx, %rax
        subq    %rsi, %rax
        movq    %rax, %rdx                  # 3rd argument: byte count
        movq    $SYS_WRITE, %rax            # write(STDOUT, screen, count)
        movq    $STDOUT, %rdi
        syscall

        movq    -8(%rbp), %rbx              # epilogue
        movq    -16(%rbp), %r12
        movq    -24(%rbp), %r13
        movq    -32(%rbp), %r14
        movq    %rbp, %rsp
        popq    %rbp
        ret

# ****************************************************************************
# * Subroutine: sleep_tick                                                   *
# * Description: Sleeps for one game tick so the game runs at a steady pace. *
# * Parameters:  none            Returns: nothing                            *
# ****************************************************************************
sleep_tick:
        pushq   %rbp
        movq    %rsp, %rbp

        movq    $SYS_NANOSLEEP, %rax        # nanosleep(&tick_spec, NULL)
        leaq    tick_spec(%rip), %rdi
        movq    $0, %rsi
        syscall

        movq    %rbp, %rsp
        popq    %rbp
        ret

# Tell the linker we do not need an executable stack
.section .note.GNU-stack,"",@progbits
