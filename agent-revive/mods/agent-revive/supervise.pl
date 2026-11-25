use strict;
use warnings;
use POSIX qw(setsid sigaction SIGCHLD SA_NOCLDSTOP SIGKILL WIFSIGNALED WTERMSIG);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

my ($script, $command) = @ARGV;
my $seconds = $ENV{HC_REVIVE_WORKER_SECONDS} // 3600;
die "invalid worker parameters" unless @ARGV == 2 && $command =~ /\A(?:tick|save)\z/
    && $seconds =~ /\A[1-9][0-9]{0,3}\z/ && $seconds <= 3600;

sub private_session {
    my $session = setsid();
    defined($session) && $session == $$ or die "setsid: $!";
}

# Detach the supervisor before spawning any work. Closing the UI exec group
# after acknowledgement must never orphan an unsupervised lock owner.
my $supervisor = fork();
die "fork: $!" unless defined $supervisor;
exit 0 if $supervisor;
private_session();

open my $entropy, '<:raw', '/dev/urandom' or die "open urandom: $!";
read($entropy, my $bytes, 16) == 16 or die "read urandom: $!";
close $entropy;
my $run = unpack 'H*', $bytes;

# This process has one child. Observe its exit without reaping it, so its PID
# and process group cannot be recycled before residual helpers are killed.
my $exited = 0;
my $handler = POSIX::SigAction->new(sub { $exited = 1 }, POSIX::SigSet->new(), SA_NOCLDSTOP);
defined(sigaction(SIGCHLD, $handler)) or die "sigaction: $!";
my $deadline = clock_gettime(CLOCK_MONOTONIC) + $seconds;
my $worker = fork();
die "fork: $!" unless defined $worker;
if ($worker == 0) {
    private_session();
    exec '/bin/zsh', $script, 'worker', $command, $run or die "exec: $!";
}

# Only the worker writes the lock/start acknowledgement. The supervisor owns
# neither its pipe nor its lock. Noninteractive helpers inherit its private group.
close STDOUT;
while (!$exited) {
    my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
    last if $remaining <= 0;
    sleep($remaining < 0.25 ? $remaining : 0.25);
}
my $expired = !$exited;
kill 'KILL', -$worker;
kill 'KILL', $worker;  # Also covers a child that has not yet created its session.
my $reaped;
do { $reaped = waitpid($worker, 0) } while $reaped < 0 && $!{EINTR};
die "waitpid: $!" unless $reaped == $worker;
my $status = $?;
my $outcome = $status == 0 ? 'succeeded' : 'failed';
$outcome = 'timed_out' if $expired && WIFSIGNALED($status) && WTERMSIG($status) == SIGKILL;
exec '/bin/zsh', $script, 'finish-worker', $run, $outcome or die "exec: $!";
