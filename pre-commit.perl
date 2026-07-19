use strict;
use warnings;

my $message = $ARGV[0];

system('odin test ./tests');

if ($? != 0){
    print "Tests failed with exit code: $?\n";
    exit 1;
}else{
    print "\nTests Succeeded\n";
    system("git add .");
    system("git commit -m \"chore: $message\"");
    system("git push");
}