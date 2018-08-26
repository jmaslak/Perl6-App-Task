#
# Copyright (C) 2015-2018 Joelle Maslak
# All Rights Reserved
#
use v6;

unit module App::Tasks;

use Digest::SHA1::Native;
use File::Temp;
use P5getpriority;
use P5localtime;

my $P1         = '[task]';
my $P2         = '> ';
my $PCOLOR     = '';
my $PBOLDCOLOR = '';
my $PINFOCOLOR = '';

# my $PCOLOR     = color('reset bold cyan');
# my $PBOLDCOLOR = color('reset bold green');
# my $PINFOCOLOR = color('reset dark cyan');
# my @PSTYLE     = ( -style => "reset bold cyan" );

my @PAGERCMD  = qw/less -RFX -P%PROMPT% -- %FILENAME%/;
my @EDITORCMD = <nano -r 72 -s ispell +3,1 %FILENAME%>;

# Fix %*ENV<SHELL> so LESS doesn't give error messages
if %*ENV<SHELL>:exists {
    if %*ENV<SHELL> eq '-bash' {
        %*ENV<SHELL> = 'bash';
    }
}

my %H_INFO = (
    title => {
        order   => 1,
        display => 'Title'
    },
    created => {
        order   => 2,
        display => 'Created',
        type    => 'date'
    }
);

my $H_LEN = %H_INFO.values.map( { .<display>.chars } );

our sub start(@args is copy) {
    chdir $*PROGRAM.parent.add("data");

    $*OUT.out-buffer = False;

    if ! @args.elems {

        my @choices = (
            [ 'Create New Task'            => 'new' ],
            [ 'Add a Note to a Task'       => 'note' ],
            [ 'View an Existing Task'      => 'show' ],
            [ 'List All Tasks'             => 'list' ],
            [ 'Monitor Task List'          => 'monitor' ],
            [ 'Move (Reprioritize) a Task' => 'move' ],
            [ 'Close a Task'               => 'close' ],
            [ 'Coalesce Tasks'             => 'coalesce' ],
            [ 'Quit to Shell'              => 'quit' ],
        );

        say "{$PCOLOR}Please select an option...\n";
        say "\n";
        my $command = menu-prompt("$P1 $P2", @choices);
        @args.push($command // 'quit');

        if ( @args[0] eq 'quit' ) { exit; }
    }

    if @args.elems == 1 {
        if @args[0] ~~ m:s/^ \d+ $/ {
            @args.unshift('view');    # We view the task if one arg entered
        }
    }

    my @validtasks = get_task_filenames().map( { Int( S/\- .* $// ); } );

    my $cmd = @args.shift.fc;
    given $cmd {
        when 'new' { task_new(|@args) }
        when 'add' { task_new(|@args) }
        when 'move' {
            if @args[0]:!exists {
                @args[0] = no-menu-prompt(
                    "$P1 Please enter source task number to move $P2",
                    @validtasks
                ) or exit;
            }
            if @args[1]:!exists {
                @args[1] = uint-prompt( "$P1 Please enter desired location of task $P2" ) or exit;
            }
            task_move(|@args);
        }
        when $_ ~~ 'show' or $_ ~~ 'view' {
            if @args[0]:!exists {
                @args[0] = no-menu-prompt(
                    "$P1 Please enter task number to show $P2",
                    @validtasks
                ) or exit;
                say "";
            }
            task_show(|@args);
        }
        when 'note' {
            if @args[0]:!exists {
                @args[0] = no-menu-prompt(
                    "$P1 Please enter task number to modify $P2",
                    @validtasks
                ) or exit;
                say "";
            }
            task_add_note(|@args);
        }
        when $_ ~~ 'close' or $_ ~~ 'commit' {
            if @args[0]:!exists {
                @args[0] = prompt(
                    "$P1 Please enter task number to close $P2",
                    [@validtasks]
                ) or exit;
                say "";
            }
            task_close(@args);
        }
        when 'list' { task-list(|@args) }
        # when 'monitor' { task_monitor(@args) }
        when 'coalesce' { task_coalesce(|@args) }
        default {
            say "WRONG USAGE";
        }
    }
}

sub get_next_sequence() {
    my @d = get_task_filenames();

    my $seq = 1;
    if @d.elems {
        $seq = pop(@d);
        $seq ~~ s/ '-' .* $//;
        $seq++;
    }

    return sprintf "%05d", $seq;
}

sub get_task_filenames() {
    return getdir().dir(test => { m:s/^ \d+ '-' .* \.task $ / }).sort;
}

sub task_new() {
    my $seq = get_next_sequence;

    my $subject = prompt( "$P1 Enter Task Subject $P2" ) or exit;
    $subject ~~ s/^\s+//;
    $subject ~~ s/\s+$//;
    $subject ~~ s:g/\t/ /;
    if ( $subject eq '' ) { say "Blank subject, exiting."; exit; }
    say "";

    my $body = get_note_from_user();

    if ( !confirm_save() ) {
        say "Aborting.";
        exit;
    }

    my $tm = time.Str;
    my $fh = "{$seq}-none.task".IO.open :w;
    $fh.say: "Title: $subject";
    $fh.say: "Created: $tm";

    if ( defined($body) ) {
        $fh.say: "--- $tm";
        $fh.print: $body;
    }

    $fh.close;

    say "Created task $seq";
}

sub get_task_filename(Int $taskint where * ~~ ^100_000 --> IO::Path:D) {
    my Str $task = sprintf( "%05d", $taskint );

    my @d = get_task_filenames();
    my @fn = @d.grep: { .basename ~~ m/^ $task '-'/ };

    if @fn.elems > 1  { die "More than one name matches\n"; }
    if @fn.elems == 1 { return @fn[0]; }
    return;
}

sub task_move(Int $old where * ~~ ^100_000, Int $new where * ~~ ^100_000) {
    if ( !check_task_log() ) {
        say "Can't move task - task numbers may have changed since last 'task list'";
        return;
    }

    my $end = get_next_sequence();
    if ( $new >= $end ) {
        $new = $end - 1;
    }
    if ( $new < 1 ) { $new = 1; }

    my $oldfn = get_task_filename($old) or die("Task not found");
    my $newfn = $oldfn;
    $newfn ~~ s/^ \d+ '-'/-/;
    $newfn = sprintf( "%05d%s", $new, $newfn );

    move $oldfn, "$newfn.tmp";

    my @d = get_task_filenames();

    if ( $new < $old ) { @d = reverse @d; }
    for @d -> $f {
        my $num = $f;
        $num ~~ s/'-' .* $//;
        if $num == $old {

            # Skip the file that isn't there anymore
            next;
        }

        my $suffix = $f;
        $suffix ~~ s/^ \d+ '-'/-/;

        if $new < $old {
            if ( ( $num >= $new ) && ( $num <= $old ) ) {
                $num = sprintf( "%05d", $num + 1 );
                move $f, "$num$suffix";
            }
        } elsif ( $new > $old ) {
            if ( ( $num <= $new ) && ( $num >= $old ) ) {
                $num = sprintf( "%05d", $num - 1 );
                move $f, "$num$suffix";
            }
        }
    }

    move "$newfn.tmp", $newfn;

}

sub task_show(Int $tasknum where * ~~ ^100_000) {
    my $task = read-task($tasknum);

    my $out    = '';
    my $header = $task<header>;
    for %H_INFO.keys.sort( { %H_INFO{$^a}<order> <=> %H_INFO{$^b}<order> } ) -> $key {
        if $header{$key}:exists {
            $out ~= sprint_header_line( $key, $header{$key} );
        }
    }
    $out ~= "\n";

    for @$task<body> -> $body {
        $out ~= sprint_body($body);
        $out ~= "\n";
    }

    display_with_pager( "Task $tasknum", $out );
}

sub read-task(Int $tasknum where * ~~ ^100_000) {
    my $task = {};
    $task<header> = Hash.new;
    $task<body>   = [];
    $task<number> = $tasknum;

    my @lines = get_task_filename($tasknum).IO.lines;
    while (@lines) {
        my $line = shift(@lines);
        chomp($line);

        if ( $line ~~ m/^ '--- ' \d+ $/ ) {
            @lines.unshift: "$line\n";
            read-task-body( $task, @lines );
            @lines = ();
            next;
        }

        # We know we are in the header.
        $line ~~ /^ ( <-[:]> + ) ':' \s* ( .* ) \s* $/;
        my ($field, $value) = @();

        $task<header>{ $field.Str.fc } = $value.Str;
    }

    return $task;
}

sub read-task-body(Hash $task is rw, @lines) {
    for @lines -> $line {
        chomp($line);

        if $line ~~ m/^ '--- ' \d+ $/ {
            my ($bodydate) = $line ~~ m/^ '--- ' (\d+) $/;
            my $body = Hash.new;
            $body<date> = $bodydate;
            $body<body> = [];

            $task<body>.push: $body;
            next;
        }

        if $task<body> {
            $task<body>[*-1]<body> ~= $line ~ "\n";
        }
    }
}

sub sprint_header_line($header, $value) {
    if %H_INFO{$header}<type>:exists and %H_INFO{$header}<type> eq 'date' {
        $value = localtime($value, :scalar);
    }

    my $out = '';

    my $len = $H_LEN;
    $out ~=
      sprintf( "%-{$len}s : %s\n", %H_INFO{$header}<display>, $value );

#--    $out ~=
#--      sprintf(
#--        color("bold green") . "%-{$len}s : " . color("bold yellow") . "%s" . color("reset") . "\n",
#--        $H_INFO{$header}{display}, $value );

    return $out;
}

sub sprint_body($body) {
#--    my $out =
#--        color("bold red") . "["
#--      . localtime $body->{date} . "]"
#--      . color('reset')
#--      . color('red') . ':'
#--      . color("reset") . "\n";
    my $out = "[" ~ localtime($body<date>, :scalar) ~ "]:\n";

    # my $coloredtext = $body<body>;
    # my $yellow      = color("yellow");
    # $coloredtext =~ s/^/$yellow/mg;
    # $out ~= $coloredtext . color("reset");
    $out ~= $body<body>;

    return $out;
}

sub task_add_note(Int $tasknum where * ~~ ^100_000) {
    if ( !check_task_log() ) {
        say "Can't add note - task numbers may have changed since last 'task list'";
        return;
    }

    add_note($tasknum);
}

sub add_note(Int $tasknum where * ~~ ^100_000) {
    task_show($tasknum);

    my $note = get_note_from_user();
    if ( !defined($note) ) {
        say "Not adding note";
        return;
    }

    if ( !( confirm_save() ) ) {
        say "Aborting.";
        exit;
    }

    my $fn = get_task_filename($tasknum) or die("Task not found");
    my $fh = $fn.open(:append);
    $fh.print: "--- " ~ time ~ "\n$note";

    say "Updated task $tasknum";
}

sub confirm_save() {
    my $result = yn-prompt(
        "$P1 Save This Task [Y/n]? $P2"
    );
    return $result;
}

sub get_note_from_user() {
    if ! @EDITORCMD.elems == 0 {
        return get_note_from_user_internal();
    } else {
        return get_note_from_user_external();
    }
}

sub get_note_from_user_internal() {
#--    print color("bold cyan") . "Enter Note Details" . color("reset");
#--    print color("cyan")
#--      . " (Use '.' on a line by itself when done)"
#--      . color("bold cyan") . ":"
#--      . color("reset") . "\n";

    say "Enter Note Details (Use '.' on a line by itself when done):";

    my $body = '';
    while lines() -> $line {
        if ( $line eq '.' ) {
            last;
        }
        $body ~= $line ~ "\n";
    }

    say "";

    if ( $body eq '' ) {
        return;
    }

    return $body;
}

sub get_note_from_user_external() {
    # External editors may pop up full screen, so you won't see any
    # history.  This helps mitigate that.
    my $result = yn-prompt( "$P1 Add a Note to This Task [Y/n]? $P2" );

    if !$result {
        return;
    }

    my $prompt = "Please enter any notes that should appear for this task below this line.";

    my ($filename, $tmp) = tempfile(:unlink);
    $tmp.say: $prompt;
    $tmp.say: '-' x 72;
    $tmp.close;

    my @cmd = map { S:g/'%FILENAME%'/$filename/ }, @EDITORCMD;
    run(@cmd);

    my @lines = $filename.IO.lines;
    if ! @lines.elems { return; }

    # Eat the header
    my $first = @lines[0];
    chomp $first;
    if $first eq $prompt { @lines.shift; }
    if @lines.elems {
        my $second = @lines[0];
        chomp($second);
        if $second eq '-' x 72 { @lines.shift; }
    }

    # Remove blank lines at top
    for @lines -> $line is copy {
        chomp $line;

        if $line ne '' {
            last;
        }
    }

    # Remove blank lines at bottom
    while @lines.elems {
        my $line = @lines[*-1];
        chomp $line;

        if $line eq '' {
            @lines.pop;
        } else {
            last;
        }
    }

    my $out = join '', @lines;
    if ( $out ne '' ) {
        return $out;
    } else {
        return;
    }
}

sub task_close(Int $tasknum where * ~~ ^100_000) {
    if ( !check_task_log() ) {
        say "Can't close task - task numbers may have changed since last 'task list'";
        return;
    }

    add_note($tasknum);

    my $fn = get_task_filename($tasknum);
    $tasknum = sprintf( "%05d", $tasknum );
    my ($meta) = $fn ~~ m/^ \d+ '-' (.*) '.task' $/;
    my $newfn = time.Str ~ "-$tasknum-$*PID-$meta.task";

    move $fn, "done/$newfn";
    say "Closed $tasknum";
    coalesce_tasks();
}

# XXX Need a non-colorized option
sub display_with_pager($description, $contents) {
    if @PAGERCMD.elems {
        my ($filename, $tmp) = tempfile(:unlink);
        $tmp.print: $contents;
        $tmp.close;

        my $out = "$description ( press h for help or q to quit ) ";

        my @pager;
        for @PAGERCMD -> $part is copy {
            $part ~~ s:g/'%PROMPT%'/$out/;
            $part ~~ s:g/'%FILENAME%'/$filename/;
            @pager.push: $part;
        }
        run(@pager);
    } else {
        print $contents;
    }
}

sub generate-task-list(Int $num? where {!$num.defined or $num > 0}, $wchars?) {
    my (@d) = get_task_filenames();
    my (@tasknums) = @d.map: { $^a.basename ~~ m/^ (\d+) /; Int($0) };

    my $out = '';
    for @tasknums.sort( { $^a <=> $^b } ) -> $tasknum {
        my $task = read-task($tasknum);

        my $title = $task<header><title>;
        my $desc  = $title;
        if ( defined($wchars) ) {
            $desc = substr( $title, 0, $wchars - $tasknum.chars - 1 );
        }
        # $out ~= "$PINFOCOLOR$tasknum $PBOLDCOLOR$desc" ~ color('reset') ~ "\n";
        $out ~= "$PINFOCOLOR$tasknum $PBOLDCOLOR$desc\n";

        if defined($num) {

            # Exit the loop if we've displayed <num> entries
            $num--;
            if ( !$num ) { last; }
        }
    }

    return $out;
}

multi task-list(Int $num? where { !$num.defined or $num > 0 }) {
    update_task_log();    # So we know we've done this.
    my $out = generate-task-list( $num, Nil );

    display_with_pager( "Tasklist", $out );
}

#--sub task_monitor() {
#--    my $terminal = Term::Cap->Tgetent( { OSPEED => 9600 } );
#--    Term::ReadKey::ReadMode('raw');
#--
#--    my $clear = $terminal->Tputs('cl');
#--
#--    my $last = 'x';    # Not '' because then we won't try to draw the initial
#--                       # screen - there will be no "type any character" prompt!
#--    while (1) {
#--        my ( $wchar, $hchar, $wpixel, $hpixel ) = GetTerminalSize(*STDOUT);
#--        if ( !defined($wchar) ) { die "Terminal not supported"; }
#--
#--        update_task_log();    # So we know we've done this.
#--        my $out = localtime() . ' local / ' . gmtime() . " UTC\n\n";
#--
#--        $out ~= generate-task-list( $hchar - 1, $wchar - 1 );
#--        if ( $out ne $last ) {
#--            $last = $out;
#--            print $clear;
#--            print $out;
#--            print color("reset") . "     ...Type any character to exit...  ";
#--        }
#--        if ( defined( Term::ReadKey::ReadKey(1) ) ) {
#--            Term::ReadKey::ReadMode('restore');
#--            say "";
#--            say "Exiting.";
#--            exit;
#--        }
#--    }
#--}

sub task_coalesce() {
    coalesce_tasks();
    say "Coalesced tasks";
}

sub coalesce_tasks() {
    my @nums = get_task_filenames().map: { S/'-' .* .* '.task' $// };

    my $i = 1;
    for @nums.sort( {$^a <=> $^b} ) -> $num {
        if $num > $i {
            my $orig = get_task_filename($num);
            my $new  = $orig;
            $new ~~ s/^ \d+ //;
            $new = sprintf( "%05d%s", $i, $new );
            move $orig, $new;
            $i++;
        } elsif $i == $num {
            $i++;
        }
    }
}

sub update_task_log() {
    my $sha = get_taskhash();

    my @terms;
    if ".taskview.status".IO.f {
        @terms = ".taskview.status".IO.lines;
    }

    my $oldhash = '';
    if (@terms) {
        $oldhash = shift(@terms);
    }

    my $tty = get_ttyname();

    if $oldhash eq $sha {
        # No need to update...
        if @terms.grep( { $_ eq $tty } ) {
            return;
        }
    } else {
        @terms = ();
    }

    my $fh = '.taskview.status'.IO.open :w;
    $fh.say: $sha;
    for @terms -> $term {
        $fh.say: $term;
    }
    $fh.say: $tty;
    $fh.close;
}

# Returns true if the task log is okay for this process.
sub check_task_log() {
    # Not a TTY?  Don't worry about this.
    if ( !isatty(0) ) { return 1; }

    my $sha = get_taskhash();

    my @terms;
    if ".taskview.status".IO.f {
        @terms = ".taskview.status".IO.lines;
    }

    my $oldhash = '';
    if @terms {
        $oldhash = @terms.shift;
    }

    # If hashes differ, it's not cool.
    if ( $oldhash ne $sha ) { return; }

    # If terminal in list, it's cool.
    my $tty = get_ttyname();
    if @terms.grep( { $^a eq $tty } ) {
        return 1;
    }

    # Not in list.
    return;
}

sub get_taskhash() {
    my $tl = generate-task-list( Int, Int );
    return sha1-hex($tl);
}

sub get_ttyname() {
    my $tty = getppid() ~ ':';
    if isatty(0) {
        $tty ~= ttyname(0);
    }

    return $tty;
}

sub getdir() {
    return $*PROGRAM.parent.add("data");
}

sub menu-prompt($prompt, @choices) {
    my %elems;

    my $max = @choices.map( { .elems } ).max;
    my $min = @choices.map( { .elems } ).min;

    if $min ≠ $min {
        die("All choice elements must be the same size");
    }

    my $cnt = 0;
    for @choices -> $choice {
        $cnt++;
        %elems{$cnt} = { description => $choice[0], value => $choice[1] };
    }

    my $width = log10($cnt) + 1;

    for %elems.keys.sort -> $key {
        my $elem = %elems{$key};

        printf "{$PBOLDCOLOR}%{$width}d.{$PINFOCOLOR} %s\n", $key, $elem<description>;
    }
       
    say "";
    print $prompt;

    for lines() -> $line {
        if %elems{$line}:exists {
            return %elems{$line}<value>;
        }

        say "";
        say "Invalid choice, please try again";
        print $prompt;
    }

    return;
}

sub no-menu-prompt($prompt, @choices) {
    say "";
    print $prompt;

    while lines() -> $line {
        if @choices.grep( { $^a eq $line } ) {
            return $line;
        }

        say "";
        say "Invalid choice, please try again";
        print $prompt;
    }

    return;
}

sub uint-prompt($prompt --> Int) {
    say "";
    print $prompt;

    while lines() -> $line {
        if $line !~~ m:s/ ^ \d+ $ / {
            return $line;
        }

        say "";
        say "Invalid number, please try again";
        say "";

        say "";
        print $prompt;
    }

    return;
}

sub str-prompt($prompt --> Str) {
    say "";
    print $prompt;

    while lines() -> $line {
        if $line ne '' {
            return $line;
        }

        say "";
        say "Invalid input, please try again";
        print $prompt;
    }

    return;
}

sub yn-prompt($prompt --> Bool) {
    say "";
    print $prompt;

    while lines() -> $line is copy {
        $line = $line.fc();
        if $line eq '' {
            return True;
        } elsif $line ~~ m/ 'y' ( 'es' )? / {
            return True;
        } elsif $line ~~ m/ 'n' ( 'o' )? / {
            return False;
        }

        say "";
        say "Invalid choice, please try again";
        print $prompt;
    }

    return;
}

# XXX We always just say "nope!" for now.
multi sub isatty(Int --> Bool) { isatty() }
multi sub isatty( --> Bool) {
    return False;
}

# XXX We always say /dev/tty
multi sub ttyname(Int --> Str) { ttyname() }
multi sub ttyname(--> Str) { '/dev/tty' }