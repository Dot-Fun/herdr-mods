use strict;
use warnings;
use POSIX qw(setsid WNOHANG);
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

my $deadline = clock_gettime(CLOCK_MONOTONIC) + $seconds;
my $expires = time() + $seconds;
my $worker = fork();
die "fork: $!" unless defined $worker;
if ($worker == 0) {
    private_session();
    exec '/bin/zsh', $script, 'worker', $command, $expires or die "exec: $!";
}

# Only the worker writes the lock/start acknowledgement. The supervisor owns
# neither its pipe nor its lock. Noninteractive helpers inherit its private group.
close STDOUT;
while (1) {
    my $reaped = waitpid($worker, WNOHANG);
    exit 0 if $reaped == $worker;
    die "waitpid: $!" if $reaped < 0;
    my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
    last if $remaining <= 0;
    sleep($remaining < 0.25 ? $remaining : 0.25);
}

# The unreaped child reserves the PID. The second signal also covers a child
# that has not yet started its session. A synced pending attempt stays inert.
kill 'KILL', -$worker;
kill 'KILL', $worker;
waitpid($worker, 0);
exit 1;
