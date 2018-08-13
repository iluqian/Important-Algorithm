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
	while(i < 5){
		if(state == GET_UP){
			getup();
			state = GO_TO_SCHOOL;
		}
		else if(state == GO_TO_SCHOOL){
			gotoschool();
			state = HAVE_LUNCH;
		}
		else if(state == HAVE_LUNCH){
			eat();
		}
		i++;
	}
	return 0;
}



