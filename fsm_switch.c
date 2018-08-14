#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

void getup(){
	puts("getup");
}
void gotoschool(){
	puts("gotoschool");
}
void eat(){
	puts("eat lunch");
}
enum{
	GET_UP,
	GO_TO_SCHOOL,
	HAVE_LUNCH,
	SLEEP,
};

int main(int argc, char *argv[]){
	int state = GET_UP;
	int i = 0;	
	while(1){
			switch(state)
			{
			case GET_UP:
				getup();
				state = GO_TO_SCHOOL;
				break;
			case GO_TO_SCHOOL:
				gotoschool();
				state = HAVE_LUNCH;
				break;
			case HAVE_LUNCH:
				eat();
				break;
			default:
				break;
			}
	//	i++;
	}
	return 0;
}
/*
  
int state = 0
while(state < 3)
{
	switch(state)
	{
		case 0:
			//Do state 0 stuff
			if(should_go_to_next_state)
				state++;
			break;
		case 1:
			//Do state 1 stuff
			if(should_go_to_next_state)
				state++;
			else if(should_go_back)
				state--;
			break;
		case 2:
			//Do state 2 stuff
			if(should_go_to_next_state)
				state++;
			else if(should_go_back_two)
				state-=2;
			break;
		default:
			break;
	}

}


*/
 

