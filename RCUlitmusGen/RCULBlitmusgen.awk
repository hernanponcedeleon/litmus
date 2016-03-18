# Generate a load-buffering LISA litmus test.
#
# Usage:
#	generate_lisa(desc);
#
# The "desc" argument is a string describing the litmus test.  This string
# is a space-separated (or "+"-separated) list consisting of one entry of
# global information followed by a list of per-rf descriptions.  The global
# information is a three-character string as follows:
#
#	[GL]: Global or local transitivity
#	[RW]: The first process reads or writes.
#	[RW]: The last process reads or writes.
#
#	For example, "GRW" would be a test for global transitivity
#	where the first process reads and the last process writes.
#
# The per-rf information describes a write-to-read operation of the form
# W-R as follows:
#
# W:	A: Use rcu_assign_pointer(), AKA w[assign].
# 	O: Use WRITE_ONCE(), AKA w[once].
#	R: Use smp_write_release(), AKA w[release].
#
#	Only one of "A", "O", or "R" may be specified for a given rf link.
#
# R:	A: Use smp_read_acquire(), AKA r[acquire].
#	C: Use control dependency.
#	D: Use data dependency.
#	l: Use lderef data dependency.
#	O: Use READ_ONCE(), AKA r[once].
#
#	Exactly one of "A", "l", or "O" may be specified for a given rf link,
#	but either or both of "C" and "D" may be added in either case.
#
# A litmus test with N processes will have N-1 W-R per-rf descriptors.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, you can access it online at
# http://www.gnu.org/licenses/gpl-2.0.html.
#
# Copyright (C) IBM Corporation, 2015
#
# Authors: Paul E. McKenney <paulmck@linux.vnet.ibm.com>

@include "RCUlitmusout.awk"

########################################################################
#
# Global variables:
#
# comment: String containing the comment field, which may be multi-line.
# initializers: String containing initializers, which may be multi-line.
# exists: String containing the "exists" clause, which may be multi-line.
# i_dir[proc_num]: Incoming (read) directive
# i_op[proc_num]: Incoming operand ("r" or "w")
# i_mod[proc_num]: Incoming modifier ("once", "acquire", ...)
# i_operand1[proc_num]: Incoming first operand (register or variable)
# i_operand2[proc_num]: Incoming second operand (register or variable)
# o_dir[proc_num]: Outgoing (write) directive
# o_op[proc_num]: Outgoing operand ("r" or "w")
# o_mod[proc_num]: Outgoing modifier ("once", "acquire", ...)
# o_operand1[proc_num]: Outgoing first operand (register or variable)
# o_operand2[proc_num]: Outgoing second operand (register or variable)
# rf[rf_num]: Read-from directive
# stmts[proc_num ":" line_num]: Marshalled LISA statements

########################################################################
#
# Initialize cycle-evaluation arrays and matrices.  Reads-from and
# in-process transitions are handled by cycle_rf and cycle_proc,
# respectively.  First-process in-process transitions are special:
# cycle_proc1.  Last-process in-process transitions depend on the type of
# the trailing access: cycle_procnR and cycl_procnW.  Each element
# is of the form "X:reason", where "X" is Sometimes, Maybe, or Never.
# The "reason" can be empty and normally will be for Never.
#
function initialize_cycle_evaluation() {
	# First-process transitions
	cycle_proc1["A"] = "Never";
	cycle_proc1["O"] = "Sometimes:No ordering";
	cycle_proc1["R"] = "Never";

	# Last-process transitions for trailing read
	cycle_procnR["A"] = "Never";
	cycle_procnR["C"] = "Sometimes:Control dependencies do not order reads";
	cycle_procnR["D"] = "Never";
	cycle_procnR["l"] = "Never";
	cycle_procnR["O"] = "Sometimes:No ordering";

	# Last-process transitions for trailing write
	cycle_procnW["A"] = "Never";
	cycle_procnW["C"] = "Never";
	cycle_procnW["D"] = "Never";
	cycle_procnW["l"] = "Never";
	cycle_procnW["O"] = "Sometimes:No ordering";

	# Read-from transitions
	cycle_rf["A:A"] = "Never";
	cycle_rf["A:C"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_rf["A:D"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_rf["A:l"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_rf["A:O"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_rf["R:A"] = "Never";
	cycle_rf["R:C"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_rf["R:D"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_rf["R:l"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_rf["R:O"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_rf["O:A"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_rf["O:C"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_rf["O:D"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_rf["O:l"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_rf["O:O"] = "Maybe:Does ARM need paired release-acquire?";

	# Process transitions
	cycle_proc["A:A"] = "Never";
	cycle_proc["A:O"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_proc["A:R"] = "Never";
	cycle_proc["C:A"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_proc["C:O"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_proc["C:R"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_proc["D:A"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_proc["D:O"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_proc["D:R"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_proc["l:A"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_proc["l:O"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_proc["l:R"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_proc["O:A"] = "Maybe:Does ARM need paired release-acquire?";
	cycle_proc["O:O"] = "Sometimes:No ordering";
	cycle_proc["O:R"] = "Maybe:Does ARM need paired release-acquire?";
}

########################################################################
#
# Check the syntax of the specified process's initial directive string.
# Complain and exit if there is a problem.
#
function gen_global_syntax(x) {
	if (x !~ /^[LG][RW][RW]$/) {
		print "Global information bad format: " x > "/dev/stderr";
		exit 1;
	}
}

########################################################################
#
# Check the syntax of the specified reads-from (rf)  directive string.
# Complain and exit if there is a problem.
#
function gen_rf_syntax(rfn, x, y) {
	if (x != "A" && x != "O" && x != "R") {
		print "Reads-from edge " rfn " bad write-side specifier: " x > "/dev/stderr";
		exit 1;
	}
	if (y ~ /[^ACDlO]/) {
		print "Reads-from edge " rfn " bad read-side specifier: " y > "/dev/stderr";
		exit 1;
	}
	if ((y ~ /A/) + (y ~ /l/) + (y ~ /O/) != 1) {
		print "Reads-from edge " rfn " only one of "AlO" in read-side specifier: " x > "/dev/stderr";
		exit 1;
	}
}

########################################################################
#
# Parse the specified process's directive string and set up that
# process's LISA statements. Arguments are as follows:
#
# p: Number of current process, based from 1.
# n: Number of processes.
# g: Global directive.
# x: Current process's read directive.
# y: Current process's write directive.
# xn: Next process's read directive, used to set up for data dependency.
#
# This function operates primarily by side effects on global variables.
#
function gen_proc(p, n, g, x, y, xn,  i, line_num, tvar, v, vn, vnn) {
	if (g ~ /^L/)
		tvar = "u0";
	else
		tvar = "v0";
	v = p - 1;
	vn = (v + 1) % n;
	vnn = (vn + 1) % n;

	# Form incoming statement base.
	if (p == 1) {
		i_mod[p] = "once";
		if (g ~ /R[RW]$/) {
			i_op[p] = "r";
			i_operand1[p] = "r1";
			i_operand2[p] = "y0";
		} else {
			i_op[p] = "w";
			i_operand1[p] = "y0";
			i_operand2[p] = "1";
		}
	} else {
		if (x ~ /A/)
			i_mod[p] = "acquire";
		else if (x ~ /l/)
			i_mod[p] = "lderef";
		else
			i_mod[p] = "once";
		i_op[p] = "r";
		i_operand1[p] = "r1";
		i_operand2[p] = "x" v;
	}

	# Form outgoing statement base.
	if (p == n ) {
		o_mod[p] = "once";
		if (g ~ /R$/) {
			o_op[p] = "r";
			o_operand1[p] = "r2";
			o_operand2[p] = tvar;
		} else {
			o_op[p] = "w";
			o_operand1[p] = tvar;
			o_operand2[p] = "2";
		}
	} else {
		if (y == "A")
			o_mod[p] = "assign";
		else if (y == "R")
			o_mod[p] = "release";
		else
			o_mod[p] = "once";
		o_op[p] = "w";
		if (x ~ /[Dl]/) {
			o_operand1[p] = "r1";
		} else {
			o_operand1[p] = "x" vn;
		}
		if (xn ~ /[Dl]/) {
			o_operand2[p] = "r3";
			initializers = initializers " " p - 1 ":r3=x" vnn ";
			initializers = initializers x" vn "=y" vnn ";
			if (p == n - 1)
				initializers = initializers " vn ":r4=y" vnn;
			else
				initializers = initializers " vn ":r4=" tvar;
		} else {
			o_operand2[p] = "1";
		}
	}

	# Output statements
	line_num = 0;
	stmts[p ":" ++line_num] = i_op[p] "[" i_mod[p] "] " i_operand1[p] " " i_operand2[p];
	if (x ~ /C/) {
		stmts[p ":" ++line_num] = "mov r4 (eq r1 r4)";
		stmts[p ":" ++line_num] = "b[] r4 CTRL" p - 1;
	}
	stmts[p ":" ++line_num] = o_op[p] "[" o_mod[p] "] " o_operand1[p] " " o_operand2[p];
	if (x ~ /C/)
		stmts[p ":" ++line_num] = "CTRL" p - 1 ":";
}

########################################################################
#
# Add a term to the exists clause.  Terms are separated by AND.
#
# e: Exists clause to add.
#
function gen_add_exists(e) {
	if (exists == "")
		exists = e;
	else
		exists = exists " /\\ " e;
}

########################################################################
#
# Generate the auxiliary process given a global-transitivity litmus test.
# This function also adds the corresponding "exists" clauses.
#
# Arguments:
#
# g: Global information descriptor
# n: Number of processes (not counting possible auxiliary process).
#
function gen_aux_proc_global(g, n,  line_num) {
	line_num = 0;
	if (g ~ /^G[RW]R$/) {
		stmts[n + 1 ":" ++line_num] = "w[once] z0 1"
		gen_add_exists(n - 1 ":r2=0");
	} else {
		stmts[n + 1 ":" ++line_num] = "r[once] r1 z0"
		gen_add_exists(n ":r1=2");
	}
	stmts[n + 1 ":" ++line_num] = "f[mb]"
	if (g ~ /^GR[RW]$/) {
		stmts[n + 1 ":" ++line_num] = "w[once] y0 1"
		gen_add_exists("0:r1=1");
	} else {
		stmts[n + 1 ":" ++line_num] = "r[once] r2 y0"
		gen_add_exists(n ":r2=0");
	}
}

########################################################################
#
# Generate the auxiliary process given a local-transitivity litmus test.
# This function also adds the corresponding "exists" clauses.
#
# Arguments:
#
# g: Global information descriptor
# n: Number of processes (not counting possible auxiliary process).
#
function gen_aux_proc_local(g, n,  line_num) {
	line_num = 0;
	if (g == "LRR") {
		stmts[n + 1 ":" ++line_num] = "w[once] y0 1"
		gen_add_exists("0:r1=1");
		gen_add_exists(n - 1 ":r2=0");
	} else if (g == "LRW") {
		gen_add_exists("0:r1=2");
	} else if (g == "LWR") {
		gen_add_exists(n - 1 ":r2=0");
	} else {
		gen_add_exists("y0=1");
	}
}

########################################################################
#
# Generate the auxiliary process for the current litmus test, if one is
# required.  One is required for tests of global transitivity (which is the
# gen_aux_proc_global() function's job) and for tests of local transitivity
# where both operations are reads (which is the gen_aux_proc_local()
# function's job).  These functions also add the corresponding "exists"
# clauses.
#
# Arguments:
#
# g: Global information descriptor
# n: Number of processes (not counting possible auxiliary process).
#
function gen_aux_proc(g, n) {
	if (g ~ /^G/)
		gen_aux_proc_global(g, n);
	else
		gen_aux_proc_local(g, n);
}

########################################################################
#
# Generate the exists clause.
#
# n: Number of processes.
#
function gen_exists(n,  proc_num, wrcmp) {
	for (proc_num = 2; proc_num <= n; proc_num++) {
		if (o_operand2[proc_num - 1] == "r3")
			wrcmp = "x" proc_num;
		else
			wrcmp = 1;
		gen_add_exists(proc_num - 1 ":" i_operand1[proc_num] "=" wrcmp);
	}
}

########################################################################
#
# Add a line to the comment.
#
# s: String to add, may contain newline character.
#
function gen_add_comment(s) {
	if (comment == "")
		comment = s;
	else
		comment = comment "\n" s;
}

########################################################################
#
# Update the running result based on the current transition
#
# oldresult: Prior running result
# desc: Description of current transition
# reasres: Reason-result combination from appropriate array
#
function result_update(oldresult, desc, reasres,  reason, result) {
	result = reasres;
	gsub(/:.*$/, "", result);
	reason = reasres;
	gsub(/^.*:/, "", reason);

	# "Things can only get worse!"  ;-)
	if (oldresult == "Sometimes" ||
	    (oldresult == "Maybe" && result == "Never"))
		result = oldresult;

	if (reason != "" && result != oldresult)
		gen_add_comment(desc ": " oldresult "->" result ": " reason);
	else if (reason != "" && result == oldresult)
		gen_add_comment(desc ": " reason);
	else if (reason == "" && result != oldresult)
		gen_add_comment(desc ": " oldresult "->" result);

	return result;
}

########################################################################
#
# Find the strongest in-bound ordering constraint
#
# cur_rf: String containing constraints
#
function best_rfin(cur_rf,  rfin) {
	if (cur_rf ~ /A/)
		rfin = "A";
	else if (cur_rf ~ /l/)
		rfin = "l";
	else if (cur_rf ~ /D/)
		rfin = "D";
	else if (cur_rf ~ /C/)
		rfin = "C";
	else
		rfin = "O";
	return rfin;
}

########################################################################
#
# Produce timing-related comment.
#
# gdir: Global directive
# n: Number of processes.
#
function gen_comment(gdir, n,  desc, result, rfin, rfn) {

	result = "Never";

	# Handle global directive ordering constraints
	if (gdir == "GWR")
		result = result_update(result, "GWR", "Sometimes:Power rel-acq does not provide write-to-read global transitivity");
	if (gdir ~ /^G/)
		result = result_update(result, gdir, "Maybe:Should rel-acq provide any global transitivity?");

	# Handle first-process ordering constraints
	result = result_update(result, o_dir[1], cycle_proc1[o_dir[1]]);

	# Handle rf and in-process constraints
	for (rfn = 1; rfn < n; rfn++) {
		rfin = best_rfin(i_dir[rfn + 1]);
		desc = "rf" rfn " " rf[rfn];
		result = result_update(result, desc, cycle_rf[o_dir[rfn] ":" rfin]);
		if (rfn == n - 1)
			break;
		desc = "P" rfn " " i_dir[rfn + 1] ":" o_dir[rfn + 1];
		result = result_update(result, desc, cycle_rf[rfin ":" o_dir[rfn + 1]);
	}

	# Handle last-process ordering constraints
	rfin = best_rfin(idir[n]);
	desc = "P" n - 1 " " i_dir[n] ":" gdir;
	if (gdir ~ /R$/)
		result = result_update(result, desc, cycle_procnR[rfin]);
	else
		result = result_update(result, desc, cycle_procnW[rfin]);

	# Print the result and stick it on the front of the comment.
	comment = "Result: " result "\n" comment;
	print " result: " result;
}

########################################################################
#
# Parse the specified process's directive string and set up that
# process's LISA statements.  The directive string is the single
# argument, and the litmus test is output to the file whose name
# is formed by separating the directives with "+".  Arguments:
#
# prefix: Filename prefix for litmus-file output.
# s: Directive string.
#
function gen_litmus(prefix, s,  gdir, i, line_num, n, name, ptemp) {

	# Delete arrays to avoid possible old cruft.
	delete i_op;
	delete i_mod;
	delete i_operand1;
	delete i_operand2;
	delete o_op;
	delete o_mod;
	delete o_operand1;
	delete o_operand2;
	delete stmts;

	exists = "";
	initializers = "";

	initialize_cycle_evaluation();

	# Generate each process's code.
	if (s ~ /+/)
		n = split(s, ptemp, "+");
	else
		n = split(s, ptemp, " ");
	if (n < 3) {
		# Smaller configurations don't rely on transitivity
		print "Not enough directives: Need global and at least two rf!";
		exit 1;
	}
	gdir = ptemp[1];
	gen_global_syntax(gdir);
	i_dir[1] = "";
	o_dir[n] = "";
	i_dir[n + 1] = "";
	for (i = 2; i <= n; i++) {
		rf[i - 1] = ptemp[i];
		o_dir[i - 1] = ptemp[i];
		gsub(/-.*$/, "", o_dir[i - 1]);
		i_dir[i] = ptemp[i];
		gsub(/^.*-/, "", i_dir[i]);
		gen_rf_syntax(ptemp[i], o_dir[i - 1], i_dir[i]);
	}
	for (i = 1; i <= n; i++) {
		if (name == "")
			name = prefix "LB-" ptemp[i];
		else
			name = name "+" ptemp[i];
		gen_proc(i, n, gdir, i_dir[i], o_dir[i], i_dir[i + 1]);
	}

	# Generate auxiliary process and exists clause, then dump it out.
	gen_aux_proc(gdir, n);
	gen_exists(n);
	printf "%s ", "name: " name ".litmus";
	gen_comment(gdir, n);
	output_lisa(name, comment, initializers, stmts, exists);
}
