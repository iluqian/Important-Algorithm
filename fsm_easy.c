#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>

int entry_state(void);
int foo_state(void);
int bar_state(void);
int exit_state(void);

int (*state[])(void) = {entry_state,foo_state,bar_state,exit_state};
enum state_codes {entry, foo, bar, end}; //状态

enum ret_codes {ok, fail, repeat};  //事件
struct transition {
	enum state_codes src_state;
	enum ret_codes ret_code;
	enum state_codes dst_state;
};

//状态机  
struct transition state_transitions[] = {
	/*当前状态, 事件, 下一个状态*/
	{entry, ok, foo},
	{entry, fail, end},
	{foo, ok, bar},
	{foo, fail, end},
	{foo, repeat, foo},
	{bar, ok, end},
	{bar, repeat, foo},
	{bar, fail, end},
	{end, repeat, entry}
};
int count = sizeof(state_transitions) / sizeof(struct transition);
#define ENTRY_STATE entry
#define EXIT_STATE end

/*当前状态和事件满足之后, 进入下一个状态*/
int lookup_transitions(int state_codes,int ret_codes)
{
	int i ;
	for(i = 0; i < count; i++)
	{
		if(state_codes == state_transitions[i].src_state && ret_codes == state_transitions[i].ret_code){
			printf("state_transitions[%d].src_state:%d;  ",i,state_transitions[i].src_state);
			printf("state_transitions[%d].dst_state:%d\n",i,state_transitions[i].dst_state);
			sleep(1);
			return state_transitions[i].dst_state;
		}
		//else 
		//		return -1;
	}
	
}
int main(int argc, char *argv[]){
	printf("count=%d\n",count);
	enum state_codes cur_state = ENTRY_STATE;
	enum ret_codes rc;
	int (*state_fun)(void);
	for(;;){
		state_fun = state[cur_state];/*使用函数指针state_fun来调用函数*/
		rc = state_fun();
		if(EXIT_STATE == cur_state)
				break;
		//状态的切换	
		cur_state = lookup_transitions(cur_state,rc);
			
	}
	return EXIT_SUCCESS;
}

int p = 0;
int entry_state(void)
{
	if(1)
	{
		printf("entry_state\n");
		return ok;
	}
	else
		return fail;
}
int foo_state(void)
{
	printf("foo_state\n");
	return ok;
}
int bar_state(void)
{
	printf("bar_state\n");
	p++;
	if(p < 3)
		return repeat;
	else 
		return ok;

}
int exit_state(void)
{
	printf("exit_state\n");
	//if(p == 0)
			return repeat;

	return fail;
}
